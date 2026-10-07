import { DurableObject } from "cloudflare:workers";

export interface QuotaLimits {
  perMinute: number;
  perMonth: number;
}

export type ConsumeResult = { allowed: true } | { allowed: false; reason: "minute_limit" | "monthly_limit" };

/** What `remaining` reports: room left in each window, as of `nowMs`. Never negative. */
export interface Remaining {
  perMinute: number;
  perMonth: number;
}

/**
 * One instance per user (`QUOTA.idFromName(userId)`). Holds usage COUNTS only:
 * one row per active window, never anything about a request's content, and not
 * even the user id.
 *
 * Atomicity: a Durable Object runs one request at a time, and `consume` does its
 * whole read-check-increment inside one synchronous `transactionSync` with no
 * `await`, so parallel requests cannot interleave between the read and the write.
 * That is the property the old KV counters could not give.
 */
export class QuotaCounter extends DurableObject {
  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS windows (kind TEXT NOT NULL, window TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (kind, window))"
    );
  }

  /**
   * Atomically checks both windows and, only if both have room, counts this
   * request in both. A denied request is not counted. Windows are derived from
   * the caller-supplied `nowMs` (UTC minute and UTC month) so tests can drive time.
   */
  consume(limits: QuotaLimits, nowMs: number): ConsumeResult {
    const minute = String(Math.floor(nowMs / 60_000));
    const month = new Date(nowMs).toISOString().slice(0, 7); // YYYY-MM
    const sql = this.ctx.storage.sql;

    return this.ctx.storage.transactionSync((): ConsumeResult => {
      // Drop windows that can never be used again (on-write pruning: one row per
      // kind stays, so an idle user costs two tiny rows).
      sql.exec("DELETE FROM windows WHERE (kind = 'minute' AND window <> ?) OR (kind = 'month' AND window <> ?)", minute, month);

      const count = (kind: string, window: string): number => {
        const row = sql.exec("SELECT count FROM windows WHERE kind = ? AND window = ?", kind, window).toArray()[0];
        return row ? Number(row.count) : 0;
      };
      const minuteCount = count("minute", minute);
      const monthCount = count("month", month);

      if (minuteCount >= limits.perMinute) return { allowed: false, reason: "minute_limit" };
      if (monthCount >= limits.perMonth) return { allowed: false, reason: "monthly_limit" };

      const upsert = "INSERT INTO windows (kind, window, count) VALUES (?, ?, 1) ON CONFLICT (kind, window) DO UPDATE SET count = count + 1";
      sql.exec(upsert, "minute", minute);
      sql.exec(upsert, "month", month);
      return { allowed: true };
    });
  }

  /**
   * Read-only: how much of each window's allowance is left, without consuming any of it (no
   * write, so no transaction is needed — a Durable Object already runs one request at a time).
   * Used by GET /v1/me to report `remainingThisMonth` without spending the user's own quota just
   * by checking it. Same window derivation as `consume`, so it reports exactly what a `consume`
   * call made at the same instant would have checked against.
   */
  remaining(limits: QuotaLimits, nowMs: number): Remaining {
    const minute = String(Math.floor(nowMs / 60_000));
    const month = new Date(nowMs).toISOString().slice(0, 7);
    const sql = this.ctx.storage.sql;
    const count = (kind: string, window: string): number => {
      const row = sql.exec("SELECT count FROM windows WHERE kind = ? AND window = ?", kind, window).toArray()[0];
      return row ? Number(row.count) : 0;
    };
    return {
      perMinute: Math.max(0, limits.perMinute - count("minute", minute)),
      perMonth: Math.max(0, limits.perMonth - count("month", month)),
    };
  }
}
