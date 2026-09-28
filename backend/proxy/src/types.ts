import type { QuotaCounter } from "./quotaCounter";

export interface Env {
  /** Per-user quota counters (Durable Object, one instance per user id). */
  QUOTA: DurableObjectNamespace<QuotaCounter>;
  SUPABASE_URL: string;
  /** How access tokens are verified: "hs256" (shared secret, the default) or "jwks" (asymmetric keys). Config only, never taken from a token. */
  JWT_VERIFY_MODE?: string;
  /** Required in hs256 mode; not used (and not needed) in jwks mode. */
  SUPABASE_JWT_SECRET?: string;
  /** jwks mode only. Default `${SUPABASE_URL}/auth/v1/.well-known/jwks.json`; off loopback it must be https on SUPABASE_URL's origin. */
  SUPABASE_JWKS_URL?: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  ANTHROPIC_API_KEY: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  /** The subscription Price to check out (one Pro plan in v1). */
  STRIPE_PRICE_ID: string;
  /**
   * Dev-only. When set, and only on a loopback hostname, the Stripe SDK client is pointed at this
   * URL (e.g. `http://127.0.0.1:54323`, `scripts/mock-stripe.mjs`) instead of api.stripe.com. Off
   * loopback this is never honored, even if somehow set (see stripeClient.ts) — the same fail-closed
   * treatment hostGuard.ts gives the Supabase JWKS URL.
   */
  STRIPE_API_BASE_URL?: string;
  /** Where Checkout sends the browser back. Optional: falls back to a placeholder page (see billing.ts). */
  BILLING_SUCCESS_URL?: string;
  BILLING_CANCEL_URL?: string;
  /** Where the Stripe customer portal sends the browser back. Optional, same fallback treatment. */
  BILLING_PORTAL_RETURN_URL?: string;
  /** Dev-only. "mock" enables the local mock LLM, and only on a loopback hostname. Never set on the deployed Worker. */
  LLM_PROVIDER?: string;
}

export type Tier = "free" | "pro";

// Placeholder limits — the TRD (Section 8's "Path to v2" and the PRD's
// open questions) is explicit that pricing and quota sizing are
// unresearched. Free gets 0 because rewrite is Pro-only in v1; the
// per-tier shape is kept in case a small free allowance is ever added.
export const TIER_LIMITS: Record<Tier, { perMinute: number; perMonth: number }> = {
  free: { perMinute: 0, perMonth: 0 },
  pro: { perMinute: 5, perMonth: 3000 },
};

/**
 * Limits for /v1/edit, which has its OWN counters (a separate Durable Object id, see rateLimit.ts),
 * so voice edits and dictation rewrites never consume each other's allowance.
 * UNRESEARCHED PLACEHOLDERS, copied from rewrite: an edit sends more text per call than a rewrite,
 * so real usage and unit cost (Day 16, task 2.9) must set these before any price is final.
 */
export const EDIT_TIER_LIMITS: Record<Tier, { perMinute: number; perMonth: number }> = {
  free: { perMinute: 0, perMonth: 0 },
  pro: { perMinute: 5, perMonth: 3000 },
};

/**
 * Limits for POST /v1/referral/redeem, keyed by the authenticated user (own Durable Object,
 * see rateLimit.ts / quotaCounter.ts). Redemption is unrelated to tier — free and Pro users
 * both get the same small cap — so both tiers hold the same numbers; the field only exists
 * to satisfy checkAndConsumeQuota's signature. The point is not throughput but making the
 * 8-hex-char referral code (32-bit space, 0002_referrals.sql's default) too slow to guess:
 * a legitimate redemption happens once, ever, so any cap above "a handful" is generous.
 */
export const REFERRAL_LIMITS: Record<Tier, { perMinute: number; perMonth: number }> = {
  free: { perMinute: 5, perMonth: 20 },
  pro: { perMinute: 5, perMonth: 20 },
};

/**
 * Limits for POST /v1/events, keyed by the caller's IP (or hostname, when no IP header is
 * present — see events.ts). The endpoint is intentionally unauthenticated, so there is no
 * tier to key on; both entries hold the same numbers for the same reason as REFERRAL_LIMITS.
 * Generous enough to never trouble a real client (each dictation completion fires at most a
 * few events), tight enough that hammering the endpoint from one source is capped.
 */
export const EVENTS_LIMITS: Record<Tier, { perMinute: number; perMonth: number }> = {
  free: { perMinute: 60, perMonth: 100_000 },
  pro: { perMinute: 60, perMonth: 100_000 },
};

/**
 * Limits for POST /v1/billing/checkout and POST /v1/billing/portal, keyed by the authenticated
 * user (own Durable Object). Both tiers hold the same numbers, same reasoning as REFERRAL_LIMITS:
 * a legitimate user creates a handful of these sessions ever, so any cap above "a handful" is
 * generous, and the point is stopping an authenticated caller from hammering Stripe session
 * creation (a real, metered call against Stripe's API, mock or not) rather than throughput.
 */
export const BILLING_LIMITS: Record<Tier, { perMinute: number; perMonth: number }> = {
  free: { perMinute: 5, perMonth: 30 },
  pro: { perMinute: 5, perMonth: 30 },
};

/**
 * Limits for GET /v1/me, keyed by the authenticated user (own Durable Object, see rateLimit.ts).
 * This route never calls a paid provider, so it is not the "no unmetered path to the paid model"
 * hard stop, but every call still does one uncached Supabase PostgREST fetch and one Durable
 * Object RPC, and without a cap an authenticated caller could hammer both for free. Both tiers
 * hold the same numbers, same reasoning as REFERRAL_LIMITS/BILLING_LIMITS. Generous on purpose:
 * the implementation plan (4.6) has the client poll this for up to two minutes after checkout,
 * and this limit is comfortably above that.
 */
export const ME_LIMITS: Record<Tier, { perMinute: number; perMonth: number }> = {
  free: { perMinute: 60, perMonth: 100_000 },
  pro: { perMinute: 60, perMonth: 100_000 },
};

/** Which counter a request draws on. Each kind has its own limits table and its own per-user counter. */
export type QuotaKind = "rewrite" | "edit" | "referral" | "events" | "billing" | "me";
export const QUOTA_LIMITS: Record<QuotaKind, Record<Tier, { perMinute: number; perMonth: number }>> = {
  rewrite: TIER_LIMITS,
  edit: EDIT_TIER_LIMITS,
  referral: REFERRAL_LIMITS,
  events: EVENTS_LIMITS,
  billing: BILLING_LIMITS,
  me: ME_LIMITS,
};

/**
 * Server-side input caps, enforced before any quota or provider work. Both apply:
 * the transcript is capped in Unicode code points (so an emoji counts once), and
 * the whole request body is capped in bytes.
 */
export const MAX_TRANSCRIPT_CHARS = 16_000;
export const MAX_BODY_BYTES = 64 * 1024;

/**
 * /v1/edit caps, all in Unicode code points (an emoji counts once), enforced before any quota or
 * provider work. The 64 KB body cap above applies too: 8,000 four-byte code points is 32,000 bytes,
 * so a maximum selection plus instruction and context always fits.
 */
export const MAX_EDIT_SELECTION_CHARS = 8_000;
export const MAX_EDIT_INSTRUCTION_CHARS = 500;
/** Optional context fields are truncated to these (a long browser tab title must not fail an edit). */
export const MAX_EDIT_CONTEXT_APP_CHARS = 100;
export const MAX_EDIT_CONTEXT_WINDOW_TITLE_CHARS = 200;
