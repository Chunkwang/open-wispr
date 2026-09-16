import type { Env, Tier } from "./types";

/** Reads the user's subscription tier from Supabase Postgres via PostgREST. */
export async function getUserTier(userId: string, env: Env): Promise<Tier> {
  const url = `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}&select=tier`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    },
  });
  if (!res.ok) return "free";

  const rows = (await res.json()) as Array<{ tier: string }>;
  return rows[0]?.tier === "pro" ? "pro" : "free";
}
