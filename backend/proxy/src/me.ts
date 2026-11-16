import type { Env, Tier } from "./types";
import { AuthUnavailableError, MisconfiguredError, authenticate } from "./auth";
import { getUserTier } from "./tier";
import { checkAndConsumeQuota, peekQuota, type RateLimitResult } from "./rateLimit";

/**
 * GET /v1/me (task 4.5). Authenticated. `{ "tier": "free"|"pro", "remainingThisMonth": number }`.
 *
 * `remainingThisMonth` reads the user's own "rewrite" Durable Object counter without consuming
 * any of it (QuotaCounter.remaining, via peekQuota) — it is what /v1/rewrite would check against
 * right now, not a cached or estimated figure, so it changes the instant a rewrite is admitted.
 *
 * Rate-limited on its own "me" Durable Object bucket (ME_LIMITS in types.ts), checked right after
 * authenticate() and before the Supabase tier lookup or the quota peek — same shared-quota-machinery
 * pattern billing.ts's authenticateAndThrottle uses for its own "billing" bucket. This route makes
 * no call to any paid provider, so it is not the "no unmetered path to the paid model" hard stop —
 * but every call still costs one uncached Supabase PostgREST fetch and one Durable Object RPC, and
 * without a cap an authenticated caller could hammer both for free. The limit is generous (well
 * above the implementation plan's "poll for up to two minutes after checkout", task 4.6) so it
 * never gets in a legitimate caller's way.
 */
export async function handleMe(request: Request, env: Env, hostname: string): Promise<Response> {
  let user;
  try {
    user = await authenticate(request, env, hostname);
  } catch (error) {
    if (error instanceof MisconfiguredError) {
      console.error(`misconfigured: ${error.reason}`);
      return json({ error: "misconfigured" }, 500);
    }
    if (error instanceof AuthUnavailableError) {
      return json({ error: "service_unavailable" }, 503);
    }
    throw error;
  }
  if (!user) return json({ error: "unauthorized" }, 401);

  // Fixed tier, since ME_LIMITS is identical for both — no tier lookup is needed just to decide
  // whether to serve the request at all (same reasoning as authenticateAndThrottle in billing.ts).
  let quota: RateLimitResult;
  try {
    quota = await checkAndConsumeQuota(user.id, "free", env, "me");
  } catch {
    return json({ error: "service_unavailable" }, 503);
  }
  if (!quota.allowed) return json({ error: quota.reason }, 429);

  let tier: Tier;
  try {
    tier = await getUserTier(user.id, env);
  } catch {
    return json({ error: "service_unavailable" }, 503);
  }

  let remaining;
  try {
    remaining = await peekQuota(user.id, tier, env, "rewrite");
  } catch {
    return json({ error: "service_unavailable" }, 503);
  }

  return json({ tier, remainingThisMonth: remaining.perMonth }, 200);
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
