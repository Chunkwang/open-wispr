export interface Env {
  RATE_LIMIT_KV: KVNamespace;
  SUPABASE_URL: string;
  SUPABASE_JWT_SECRET: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  ANTHROPIC_API_KEY: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
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
