import { jwtVerify } from "jose";
import type { Env } from "./types";
import { supabaseBaseUrl } from "./supabaseUrl";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface AuthedUser {
  id: string;
}

/**
 * Verifies the Supabase-issued JWT locally (HS256) — no round trip to Supabase needed.
 * Beyond the signature, the token must be an end-user session (`aud` is
 * "authenticated") issued by this project (`iss` is `${SUPABASE_URL}/auth/v1`),
 * so a token minted for another audience or another Supabase project is rejected.
 * `exp` and a UUID `sub` are required. `aud` may be a string or a list containing "authenticated".
 */
export async function authenticate(request: Request, env: Env): Promise<AuthedUser | null> {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length);

  const supabaseUrl = supabaseBaseUrl(env.SUPABASE_URL);
  if (!supabaseUrl) return null;

  try {
    const secret = new TextEncoder().encode(env.SUPABASE_JWT_SECRET);
    const { payload } = await jwtVerify(token, secret, {
      algorithms: ["HS256"],
      audience: "authenticated",
      issuer: `${supabaseUrl}/auth/v1`,
      // A token that never expires, or has no subject, is not a session.
      requiredClaims: ["exp", "sub"],
    });
    // Supabase user ids are UUIDs; anything else never reaches a URL or a quota key.
    if (typeof payload.sub !== "string" || !UUID.test(payload.sub)) return null;
    return { id: payload.sub };
  } catch {
    return null;
  }
}
