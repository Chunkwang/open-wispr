import type { Env, QuotaKind, Tier } from "./types";
import { QUOTA_LIMITS } from "./types";
import type { ConsumeResult, Remaining } from "./quotaCounter";

export type RateLimitResult = ConsumeResult;

/** A hung or unreachable quota store becomes a 503 instead of a hung request. */
export const QUOTA_DEADLINE_MS = 3000;

/**
 * Hard, server-side per-user quota — checked BEFORE the Claude API call.
 * TRD Section 3.3: client-side tier gating alone is trivially bypassable
 * by anyone calling this proxy directly with a valid token, so this is
 * the actual control, not the UI.
 *
 * The counting is done by the user's QuotaCounter Durable Object, which checks
 * and increments atomically. Throws if the store fails or misses the deadline;
 * the caller answers 503. A request counts as soon as it is admitted, and is
 * not refunded if the provider then fails.
 *
 * Each `kind` has its own counter: rewrite keeps the bare user id (so existing counters carry on),
 * every other kind uses `"<kind>:<userId>"`, a different Durable Object, so the kinds cannot consume
 * each other's allowance. A user id is a UUID and never contains ":", so ids cannot collide.
 */
export async function checkAndConsumeQuota(userId: string, tier: Tier, env: Env, kind: QuotaKind = "rewrite"): Promise<RateLimitResult> {
  const stub = env.QUOTA.get(env.QUOTA.idFromName(kind === "rewrite" ? userId : `${kind}:${userId}`));
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("quota store timed out")), QUOTA_DEADLINE_MS);
  });
  try {
    return await Promise.race([stub.consume(QUOTA_LIMITS[kind][tier], Date.now()), deadline]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Read-only counterpart to checkAndConsumeQuota: reports how much allowance is left without
 * spending any of it. Same Durable Object, same id derivation, same 3 s deadline (a hung store
 * must not hang GET /v1/me). Throws on failure or timeout; the caller answers 503.
 */
export async function peekQuota(userId: string, tier: Tier, env: Env, kind: QuotaKind = "rewrite"): Promise<Remaining> {
  const stub = env.QUOTA.get(env.QUOTA.idFromName(kind === "rewrite" ? userId : `${kind}:${userId}`));
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("quota store timed out")), QUOTA_DEADLINE_MS);
  });
  try {
    return await Promise.race([stub.remaining(QUOTA_LIMITS[kind][tier], Date.now()), deadline]);
  } finally {
    clearTimeout(timer);
  }
}
