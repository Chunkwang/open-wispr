import { jwtVerify } from "jose";
import type { Env } from "./types";

export interface AuthedUser {
  id: string;
}

/** Verifies the Supabase-issued JWT locally (HS256) — no round trip to Supabase needed. */
export async function authenticate(request: Request, env: Env): Promise<AuthedUser | null> {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length);

  try {
    const secret = new TextEncoder().encode(env.SUPABASE_JWT_SECRET);
    const { payload } = await jwtVerify(token, secret, { algorithms: ["HS256"] });
    if (typeof payload.sub !== "string") return null;
    return { id: payload.sub };
  } catch {
    return null;
  }
}
