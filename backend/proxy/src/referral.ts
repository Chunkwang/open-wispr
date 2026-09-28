import type { Env } from "./types";
import { MAX_BODY_BYTES } from "./types";
import { AuthUnavailableError, MisconfiguredError, authenticate, type AuthedUser } from "./auth";
import { supabaseBaseUrl } from "./supabaseUrl";
import { readBodyCapped } from "./httpBody";
import { checkAndConsumeQuota, type RateLimitResult } from "./rateLimit";

interface RedeemRequest {
  code?: unknown;
}

interface RedeemSuccess {
  ok: true;
  referrer_id: string;
  referee_id: string;
  trial_extended: boolean;
}

interface RedeemError {
  ok: false;
  error: string;
}

type RedeemResponse = RedeemSuccess | RedeemError;

/**
 * Handles POST /v1/referral/redeem
 *
 * Rules:
 *  - User must be authenticated with a valid Supabase JWT token. Goes through the same
 *    authenticate() as /v1/rewrite and /v1/edit, so a misconfigured deploy (bad JWT_VERIFY_MODE,
 *    an off-loopback local-dev secret, an unsafe JWKS URL) refuses to serve here too, instead of
 *    happily verifying forged tokens while the metered routes are 500ing closed.
 *  - Body is capped at MAX_BODY_BYTES, same as rewrite/edit: 413 before anything else runs.
 *  - Payload must contain non-empty `code` string.
 *  - Per-user redemption attempts are rate-limited (own Durable Object counter; see
 *    REFERRAL_LIMITS in types.ts) so the 8-hex-char code space cannot be brute-forced for free
 *    by an authenticated caller.
 *  - Rejects self-referral (referrer_id == referee_id).
 *  - Rejects unknown referral codes.
 *  - Rejects already redeemed referrals (one redemption per user).
 *  - On success, records referral pair and grants trial extension.
 */
export async function handleReferralRedeem(request: Request, env: Env, hostname: string): Promise<Response> {
  let user: AuthedUser | null;
  try {
    user = await authenticate(request, env, hostname);
  } catch (error) {
    if (error instanceof MisconfiguredError) {
      console.error(`misconfigured: ${error.reason}`);
      return json({ ok: false, error: "misconfigured" }, 500);
    }
    if (error instanceof AuthUnavailableError) {
      return json({ ok: false, error: "service_unavailable" }, 503);
    }
    throw error;
  }
  if (!user) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const bodyResult = await readBodyCapped(request, MAX_BODY_BYTES);
  if (bodyResult.kind === "too_large") return json({ ok: false, error: "body_too_large" }, 413);
  if (bodyResult.kind === "bad_encoding") return json({ ok: false, error: "invalid_json" }, 400);

  let body: RedeemRequest;
  try {
    body = JSON.parse(bodyResult.text) as RedeemRequest;
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const code = typeof body.code === "string" ? body.code.trim().toLowerCase() : "";
  if (!code) {
    return json({ ok: false, error: "missing_code" }, 400);
  }

  // Throttle before any Supabase lookup: a denied attempt must not cost a database round trip,
  // and an attacker guessing codes must not get free tries just because the code was malformed
  // in a way that would fail anyway.
  let quota: RateLimitResult;
  try {
    quota = await checkAndConsumeQuota(user.id, "free", env, "referral");
  } catch {
    return json({ ok: false, error: "service_unavailable" }, 503);
  }
  if (!quota.allowed) {
    return json({ ok: false, error: quota.reason }, 429);
  }

  // Handle mock mode / testing environments
  if (env.LLM_PROVIDER === "mock" || !env.SUPABASE_SERVICE_ROLE_KEY) {
    if (code === "selfcode") {
      return json({ ok: false, error: "self_referral_not_allowed" }, 400);
    }
    if (code === "usedcode") {
      return json({ ok: false, error: "already_redeemed" }, 400);
    }
    if (code === "unknowncode") {
      return json({ ok: false, error: "unknown_referral_code" }, 404);
    }
    return json({
      ok: true,
      referrer_id: "00000000-0000-0000-0000-000000000001",
      referee_id: user.id,
      trial_extended: true,
    }, 200);
  }

  const supabaseUrl = supabaseBaseUrl(env.SUPABASE_URL);
  if (!supabaseUrl) {
    return json({ ok: false, error: "service_unavailable" }, 503);
  }

  // 1. Query profiles table for referrer with matching referral_code
  const profilesUrl = `${supabaseUrl}/rest/v1/profiles?referral_code=eq.${encodeURIComponent(code)}&select=id`;
  const referrerRes = await fetch(profilesUrl, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    },
  });

  if (!referrerRes.ok) {
    return json({ ok: false, error: "database_error" }, 500);
  }

  const referrers = (await referrerRes.json()) as Array<{ id: string }>;
  if (referrers.length === 0) {
    return json({ ok: false, error: "unknown_referral_code" }, 404);
  }

  const referrerId = referrers[0].id;
  if (referrerId === user.id) {
    return json({ ok: false, error: "self_referral_not_allowed" }, 400);
  }

  // 2. Check if user already redeemed a referral code
  const referralsUrl = `${supabaseUrl}/rest/v1/referrals?referee_id=eq.${user.id}&select=id`;
  const existingRes = await fetch(referralsUrl, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    },
  });

  if (!existingRes.ok) {
    return json({ ok: false, error: "database_error" }, 500);
  }

  const existing = (await existingRes.json()) as Array<{ id: string }>;
  if (existing.length > 0) {
    return json({ ok: false, error: "already_redeemed" }, 400);
  }

  // 3. Record redemption pair
  const insertUrl = `${supabaseUrl}/rest/v1/referrals`;
  const insertRes = await fetch(insertUrl, {
    method: "POST",
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
      prefer: "return=representation",
    },
    body: JSON.stringify({
      referrer_id: referrerId,
      referee_id: user.id,
      code,
    }),
  });

  if (!insertRes.ok) {
    return json({ ok: false, error: "redemption_failed" }, 500);
  }

  return json({
    ok: true,
    referrer_id: referrerId,
    referee_id: user.id,
    trial_extended: true,
  }, 200);
}

function json(data: RedeemResponse, status: number): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}
