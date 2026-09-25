import { runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  baseEnv,
  brokenQuotaEnv,
  call,
  claudeReply,
  freezeClock,
  hangingQuotaEnv,
  installUpstream,
  jsonReply,
  mintToken,
  newUserId,
  restoreClock,
  restoreUpstream,
  tierReply,
  type Upstream,
} from "./helpers";
import { TIER_LIMITS } from "../src/types";
import type { QuotaCounter } from "../src/quotaCounter";

let upstream: Upstream;
beforeEach(() => {
  upstream = installUpstream();
});
afterEach(() => {
  restoreClock();
  restoreUpstream();
});

const post = (token: string, transcript = "hello") => call({ token, json: { transcript } });

async function statuses(responses: Promise<Response>[]) {
  const results = await Promise.all(responses);
  const bodies = await Promise.all(results.map((r) => r.clone().json() as Promise<Record<string, unknown>>));
  return {
    ok: results.filter((r) => r.status === 200).length,
    limited: results.filter((r) => r.status === 429).length,
    other: results.filter((r) => r.status !== 200 && r.status !== 429).map((r) => r.status),
    limitReasons: new Set(bodies.filter((_, i) => results[i].status === 429).map((b) => b.error)),
  };
}

function counterFor(userId: string) {
  return baseEnv.QUOTA.get(baseEnv.QUOTA.idFromName(userId));
}

describe("atomic quota (real Durable Object, through the Worker)", () => {
  it("20 parallel requests from one user with a limit of 5 per minute: exactly 5 succeed, 15 get minute_limit, provider called 5 times", async () => {
    freezeClock();
    // Ten independent rounds, each with a fresh user, to show it is not a lucky interleaving.
    for (let round = 0; round < 10; round++) {
      upstream.calls.length = 0;
      const token = await mintToken({ sub: newUserId() });
      const r = await statuses(Array.from({ length: 20 }, () => post(token)));
      expect(r, `round ${round}`).toMatchObject({ ok: 5, limited: 15, other: [] });
      expect([...r.limitReasons]).toEqual(["minute_limit"]);
      expect(upstream.anthropicCalls(), `round ${round}`).toHaveLength(5);
    }
  });

  it("holds under a much larger burst (100 parallel)", async () => {
    freezeClock();
    const token = await mintToken({ sub: newUserId() });
    const r = await statuses(Array.from({ length: 100 }, () => post(token)));
    expect(r).toMatchObject({ ok: 5, limited: 95, other: [] });
    expect(upstream.anthropicCalls()).toHaveLength(5);
  });

  it("different users do not share a counter (two users, interleaved parallel bursts)", async () => {
    freezeClock();
    const a = await mintToken({ sub: newUserId() });
    const b = await mintToken({ sub: newUserId() });
    const requests = Array.from({ length: 40 }, (_, i) => post(i % 2 === 0 ? a : b));
    const results = await Promise.all(requests);
    const byUser = (offset: number) => results.filter((_, i) => i % 2 === offset).map((r) => r.status);
    for (const statusList of [byUser(0), byUser(1)]) {
      expect(statusList.filter((s) => s === 200)).toHaveLength(5);
      expect(statusList.filter((s) => s === 429)).toHaveLength(15);
    }
    expect(upstream.anthropicCalls()).toHaveLength(10);
  });

  it("the counter resets in the next minute window", async () => {
    const clock = freezeClock();
    const token = await mintToken({ sub: newUserId() });
    expect(await statuses(Array.from({ length: 8 }, () => post(token)))).toMatchObject({ ok: 5, limited: 3 });

    clock.advance(20_000); // still the same minute (frozen at :30)
    expect((await post(token)).status).toBe(429);

    clock.advance(40_000); // next minute
    expect(await statuses(Array.from({ length: 8 }, () => post(token)))).toMatchObject({ ok: 5, limited: 3 });
  });

  it("counts attempts: a provider failure (502) is not refunded", async () => {
    freezeClock();
    upstream.anthropic = () => jsonReply({ type: "error", error: { type: "api_error", message: "x" } }, 500);
    const token = await mintToken({ sub: newUserId() });
    for (let i = 0; i < 5; i++) expect((await post(token)).status).toBe(502);
    expect((await post(token)).status).toBe(429);
    expect(upstream.anthropicCalls()).toHaveLength(5);
  });

  it("does not consume quota for anything rejected earlier (401, 400, 413, 402)", async () => {
    freezeClock();
    const userId = newUserId();
    const token = await mintToken({ sub: userId });
    const forged = (await mintToken({ sub: userId })).slice(0, -4) + "AAAA";
    let tier = "free";
    upstream.supabase = () => tierReply(tier);

    const rejected = [
      () => call({ json: { transcript: "x" } }), // no token
      () => call({ token: forged, json: { transcript: "x" } }), // tampered
      () => call({ token, body: "{not json" }), // 400
      () => call({ token, json: { transcript: "  " } }), // 400
      () => call({ token, json: { transcript: "a".repeat(16_001) } }), // 413
      () => call({ token, json: { transcript: "x" } }), // 402 (free)
    ];
    const expected = [401, 401, 400, 400, 413, 402];
    for (let round = 0; round < 8; round++) {
      for (let i = 0; i < rejected.length; i++) expect((await rejected[i]()).status).toBe(expected[i]);
    }
    expect(upstream.anthropicCalls()).toHaveLength(0);

    // The counter never saw a request: no rows at all.
    const rows = await runInDurableObject(counterFor(userId), (_i, state) =>
      state.storage.sql.exec("SELECT COUNT(*) AS n FROM windows").one().n
    );
    expect(rows).toBe(0);

    // And the full allowance is still there once the user is Pro.
    tier = "pro";
    expect(await statuses(Array.from({ length: 10 }, () => post(token)))).toMatchObject({ ok: 5, limited: 5 });
  });
});

describe("quota store failure (503)", () => {
  it("a failing Durable Object answers 503 service_unavailable and never reaches the provider", async () => {
    const token = await mintToken({ sub: newUserId() });
    const res = await call({ token, json: { transcript: "hello" }, env: brokenQuotaEnv() });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "service_unavailable" });
    expect(upstream.anthropicCalls()).toHaveLength(0);
  });

  it("a hung Durable Object is cut off at 3 s and answered 503", async () => {
    const token = await mintToken({ sub: newUserId() });
    const started = performance.now();
    const res = await call({ token, json: { transcript: "hello" }, env: hangingQuotaEnv() });
    const elapsed = performance.now() - started;
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "service_unavailable" });
    expect(elapsed).toBeGreaterThanOrEqual(2500);
    expect(elapsed).toBeLessThan(6000);
    expect(upstream.anthropicCalls()).toHaveLength(0);
  }, 10_000);
});

describe("QuotaCounter Durable Object (direct)", () => {
  const T = Date.UTC(2026, 8, 25, 12, 30, 15); // 2026-09-25 12:30:15 UTC
  const NEXT_MONTH = Date.UTC(2026, 9, 1, 0, 0, 5);

  it("uses the tier limits from the Worker (Pro 5/min, Free 0)", () => {
    expect(TIER_LIMITS.pro.perMinute).toBe(5);
    expect(TIER_LIMITS.free).toEqual({ perMinute: 0, perMonth: 0 });
  });

  it("allows exactly perMinute requests in a minute, then minute_limit; a denial is not counted", async () => {
    const stub = counterFor(newUserId());
    const limits = { perMinute: 3, perMonth: 100 };
    for (let i = 0; i < 3; i++) expect(await stub.consume(limits, T + i)).toEqual({ allowed: true });
    for (let i = 0; i < 10; i++) expect(await stub.consume(limits, T + 10 + i)).toEqual({ allowed: false, reason: "minute_limit" });
    const counts = await runInDurableObject(stub, (_i: QuotaCounter, state) =>
      state.storage.sql.exec("SELECT kind, count FROM windows ORDER BY kind").toArray()
    );
    expect(counts).toEqual([
      { kind: "minute", count: 3 },
      { kind: "month", count: 3 },
    ]);
  });

  it("the minute window resets at the next minute boundary, exactly", async () => {
    const stub = counterFor(newUserId());
    const limits = { perMinute: 2, perMonth: 100 };
    const minuteStart = T - (T % 60_000);
    expect((await stub.consume(limits, minuteStart)).allowed).toBe(true);
    expect((await stub.consume(limits, minuteStart + 59_999)).allowed).toBe(true);
    expect(await stub.consume(limits, minuteStart + 59_999)).toEqual({ allowed: false, reason: "minute_limit" });
    expect((await stub.consume(limits, minuteStart + 60_000)).allowed).toBe(true);
  });

  it("month exhaustion returns monthly_limit, and the month window resets on the 1st (UTC)", async () => {
    const stub = counterFor(newUserId());
    const limits = { perMinute: 100, perMonth: 4 };
    // Spread over different minutes so only the monthly cap can bind.
    for (let i = 0; i < 4; i++) expect((await stub.consume(limits, T + i * 60_000)).allowed).toBe(true);
    expect(await stub.consume(limits, T + 10 * 60_000)).toEqual({ allowed: false, reason: "monthly_limit" });
    expect(await stub.consume(limits, T + 11 * 60_000)).toEqual({ allowed: false, reason: "monthly_limit" });
    expect((await stub.consume(limits, NEXT_MONTH)).allowed).toBe(true);
    // Last millisecond of the previous month is a different window from the first of the next.
    const other = counterFor(newUserId());
    const firstOfMonth = Date.UTC(2026, 9, 1);
    expect((await other.consume({ perMinute: 100, perMonth: 1 }, firstOfMonth - 1)).allowed).toBe(true);
    expect((await other.consume({ perMinute: 100, perMonth: 1 }, firstOfMonth - 1)).allowed).toBe(false);
    expect((await other.consume({ perMinute: 100, perMonth: 1 }, firstOfMonth)).allowed).toBe(true);
  });

  it("checks the minute limit before the monthly limit", async () => {
    const stub = counterFor(newUserId());
    const limits = { perMinute: 1, perMonth: 1 };
    await stub.consume(limits, T);
    expect(await stub.consume(limits, T)).toEqual({ allowed: false, reason: "minute_limit" });
  });

  it("denies everything for zero limits (Free tier)", async () => {
    const stub = counterFor(newUserId());
    expect(await stub.consume(TIER_LIMITS.free, T)).toEqual({ allowed: false, reason: "minute_limit" });
  });

  it("is atomic: 60 parallel consume calls against a limit of 7 admit exactly 7", async () => {
    const stub = counterFor(newUserId());
    const results = await Promise.all(Array.from({ length: 60 }, () => stub.consume({ perMinute: 7, perMonth: 1000 }, T)));
    expect(results.filter((r) => r.allowed)).toHaveLength(7);
  });

  it("stores counts only, and prunes expired windows on write", async () => {
    const stub = counterFor(newUserId());
    const limits = { perMinute: 100, perMonth: 100 };
    for (let i = 0; i < 5; i++) await stub.consume(limits, T + i * 60_000); // five different minutes
    await stub.consume(limits, NEXT_MONTH);

    const { tables, columns, rows } = await runInDurableObject(stub, (_i: QuotaCounter, state) => {
      const sql = state.storage.sql;
      return {
        tables: sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'sqlite_%'").toArray(),
        columns: sql.exec("SELECT name FROM pragma_table_info('windows') ORDER BY cid").toArray(),
        rows: sql.exec("SELECT kind, window, count FROM windows ORDER BY kind").toArray(),
      };
    });
    expect(tables).toEqual([{ name: "windows" }]);
    expect(columns).toEqual([{ name: "kind" }, { name: "window" }, { name: "count" }]);
    // One row per kind: old minute and month windows are gone.
    expect(rows).toEqual([
      { kind: "minute", window: String(Math.floor(NEXT_MONTH / 60_000)), count: 1 },
      { kind: "month", window: "2026-10", count: 1 },
    ]);
  });

  it("keeps each user's counter separate", async () => {
    const limits = { perMinute: 1, perMonth: 10 };
    const a = counterFor(newUserId());
    const b = counterFor(newUserId());
    expect((await a.consume(limits, T)).allowed).toBe(true);
    expect((await a.consume(limits, T)).allowed).toBe(false);
    expect((await b.consume(limits, T)).allowed).toBe(true);
  });
});
