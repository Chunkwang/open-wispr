import type { QuotaCounter } from "./quotaCounter";

export interface Env {
  /** Per-user quota counters (Durable Object, one instance per user id). */
  QUOTA: DurableObjectNamespace<QuotaCounter>;
  SUPABASE_URL: string;
  SUPABASE_JWT_SECRET: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  ANTHROPIC_API_KEY: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
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
 * Server-side input caps, enforced before any quota or provider work. Both apply:
 * the transcript is capped in Unicode code points (so an emoji counts once), and
 * the whole request body is capped in bytes.
 */
export const MAX_TRANSCRIPT_CHARS = 16_000;
export const MAX_BODY_BYTES = 64 * 1024;
