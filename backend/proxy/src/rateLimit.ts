import type { Env, Tier } from "./types";
import { TIER_LIMITS } from "./types";
import type { ConsumeResult } from "./quotaCounter";

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
 */
export async function checkAndConsumeQuota(userId: string, tier: Tier, env: Env): Promise<RateLimitResult> {
  const stub = env.QUOTA.get(env.QUOTA.idFromName(userId));
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("quota store timed out")), QUOTA_DEADLINE_MS);
  });
  try {
    return await Promise.race([stub.consume(TIER_LIMITS[tier], Date.now()), deadline]);
  } finally {
    clearTimeout(timer);
  }
}
