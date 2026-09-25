import type { Env, Tier } from "./types";

/**
 * The tier could not be determined (Supabase down, non-OK response, dropped
 * connection, malformed reply). Distinct from "free": callers must not treat
 * it as a tier. The message is fixed on purpose: no upstream details.
 */
export class TierLookupError extends Error {
  constructor() {
    super("tier lookup failed");
    this.name = "TierLookupError";
  }
}

/**
 * Reads the user's subscription tier from Supabase Postgres via PostgREST.
 * A 200 with no row, or a tier other than "pro", is "free". Any failure to get
 * an answer throws TierLookupError.
 */
export async function getUserTier(userId: string, env: Env): Promise<Tier> {
  const url = `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${encodeURIComponent(userId)}&select=tier`;
  let rows: unknown;
  try {
    const res = await fetch(url, {
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      },
    });
    if (!res.ok) throw new TierLookupError();
    rows = await res.json();
  } catch {
    throw new TierLookupError();
  }
  if (!Array.isArray(rows)) throw new TierLookupError();
  return (rows[0] as { tier?: unknown } | undefined)?.tier === "pro" ? "pro" : "free";
}
