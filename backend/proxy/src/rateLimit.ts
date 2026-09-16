import type { Env, Tier } from "./types";
import { TIER_LIMITS } from "./types";

export interface RateLimitResult {
  allowed: boolean;
  reason?: "minute_limit" | "monthly_limit";
}

/**
 * Hard, server-side per-user quota — checked BEFORE the Claude API call.
 * TRD Section 3.3: client-side tier gating alone is trivially bypassable
 * by anyone calling this proxy directly with a valid token, so this is
 * the actual control, not the UI.
 */
export async function checkAndConsumeQuota(userId: string, tier: Tier, env: Env): Promise<RateLimitResult> {
  const limits = TIER_LIMITS[tier];
  const now = new Date();

  const minuteKey = `rl:min:${userId}:${now.toISOString().slice(0, 16)}`; // YYYY-MM-DDTHH:MM
  const monthKey = `rl:month:${userId}:${now.toISOString().slice(0, 7)}`; // YYYY-MM

  const [minuteCountRaw, monthCountRaw] = await Promise.all([
    env.RATE_LIMIT_KV.get(minuteKey),
    env.RATE_LIMIT_KV.get(monthKey),
  ]);
  const minuteCount = Number(minuteCountRaw ?? 0);
  const monthCount = Number(monthCountRaw ?? 0);

  if (minuteCount >= limits.perMinute) return { allowed: false, reason: "minute_limit" };
  if (monthCount >= limits.perMonth) return { allowed: false, reason: "monthly_limit" };

  await Promise.all([
    env.RATE_LIMIT_KV.put(minuteKey, String(minuteCount + 1), { expirationTtl: 120 }),
    env.RATE_LIMIT_KV.put(monthKey, String(monthCount + 1), { expirationTtl: 60 * 60 * 24 * 40 }),
  ]);

  return { allowed: true };
}
