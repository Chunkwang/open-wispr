import { createRemoteJWKSet, errors, jwtVerify, type JWTVerifyGetKey } from "jose";
import type { Env } from "./types";
import { supabaseBaseUrl } from "./supabaseUrl";
import { jwksUrl, jwtVerifyMode, unsafeJwksUrlOffLoopback, unsafeJwtSecretOffLoopback } from "./hostGuard";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface AuthedUser {
  id: string;
}

/**
 * The token could not be judged because the key source failed (JWKS unreachable,
 * timed out, or malformed). It says nothing about the user's token, so the caller
 * answers 503, never 401: a 401 would push the client into refresh and sign-out.
 * Carries no detail on purpose.
 */
export class AuthUnavailableError extends Error {
  constructor() {
    super("auth_unavailable");
  }
}

/**
 * The deployment is misconfigured in a way that would make authentication unsafe
 * (an unknown JWT_VERIFY_MODE, a deployed Worker holding a local-dev or too-short
 * JWT secret, or a JWKS URL that is not https on the project's own origin). The
 * caller must answer 500 without saying why, and log `reason` under a fixed
 * "misconfigured: " prefix. Every route that calls `authenticate()` gets this
 * check for free and in the same order, so no route can forget it (the bug this
 * type exists to prevent: a route that calls `authenticate()` directly without
 * first running these guards would authenticate forged tokens on a misconfigured
 * deploy instead of refusing to serve).
 */
export class MisconfiguredError extends Error {
  constructor(public readonly reason: string) {
    super("misconfigured");
  }
}

/** Algorithm allow-lists per mode. "none" is in neither, and one mode's algorithms are never accepted in the other. */
const ALGORITHMS = { hs256: ["HS256"], jwks: ["ES256", "RS256"] } as const;

const JWKS_TIMEOUT_MS = 3000;
const JWKS_CACHE_MAX_AGE_MS = 600_000;
const JWKS_COOLDOWN_MS = 30_000;

/** One remote key set per JWKS URL for the life of the isolate, so keys are cached across requests. */
const keySets = new Map<string, JWTVerifyGetKey>();

function remoteKeys(url: URL): JWTVerifyGetKey {
  const cached = keySets.get(url.href);
  if (cached) return cached;
  const remote = createRemoteJWKSet(url, {
    timeoutDuration: JWKS_TIMEOUT_MS,
    cacheMaxAge: JWKS_CACHE_MAX_AGE_MS,
    cooldownDuration: JWKS_COOLDOWN_MS,
  });
  const keys: JWTVerifyGetKey = async (header, token) => {
    try {
      return await remote(header, token);
    } catch (error) {
      // The token chose a key we do not have (or an ambiguous one): that is the token's fault, a 401.
      // Except when the key set has no keys at all: that is a project or config problem (a legacy
      // HS256 project serves an empty set), not a bad token, and a 401 would sign every user out.
      if (error instanceof errors.JWKSNoMatchingKey || error instanceof errors.JWKSMultipleMatchingKeys) {
        if (error instanceof errors.JWKSNoMatchingKey && (remote.jwks()?.keys.length ?? 0) === 0) throw new AuthUnavailableError();
        throw error;
      }
      // Everything else here is the key source failing (fetch error, timeout, non-200, bad JSON, bad JWKS).
      throw new AuthUnavailableError();
    }
  };
  keySets.set(url.href, keys);
  return keys;
}

/**
 * Verifies the Supabase-issued JWT locally, in the mode set by JWT_VERIFY_MODE
 * (config only; nothing in the token can choose it, and `jku`, `x5u` and `jwk`
 * headers are never followed):
 *  - hs256 (default): HS256 with the shared SUPABASE_JWT_SECRET; no network call.
 *  - jwks: ES256 or RS256 against the project's JWKS (cached, 3 s fetch timeout).
 * Beyond the signature, the token must be an end-user session (`aud` is
 * "authenticated") issued by this project (`iss` is `${SUPABASE_URL}/auth/v1`),
 * so a token minted for another audience or another Supabase project is rejected.
 * `exp` and a UUID `sub` are required. `aud` may be a string or a list containing "authenticated".
 *
 * Returns null for anything wrong with the token or the configuration (fail closed).
 * Throws AuthUnavailableError only when the JWKS could not be fetched or parsed, and
 * MisconfiguredError when the deployment itself is unsafe to serve (checked first,
 * before the Authorization header is even read, so a misconfigured deploy answers
 * 500 for every caller, authenticated or not).
 */
export async function authenticate(request: Request, env: Env, hostname: string): Promise<AuthedUser | null> {
  const mode = jwtVerifyMode(env);
  if (mode === null) throw new MisconfiguredError("JWT_VERIFY_MODE must be hs256 or jwks");
  if (unsafeJwtSecretOffLoopback(env, hostname)) {
    throw new MisconfiguredError("refusing to serve with a local-dev or too-short JWT secret");
  }
  if (unsafeJwksUrlOffLoopback(env, hostname)) {
    throw new MisconfiguredError("refusing to serve with a JWKS URL that is not https on the project origin");
  }

  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length);

  const supabaseUrl = supabaseBaseUrl(env.SUPABASE_URL);
  if (!supabaseUrl) return null;

  const options = {
    algorithms: [...ALGORITHMS[mode]],
    audience: "authenticated",
    issuer: `${supabaseUrl}/auth/v1`,
    // A token that never expires, or has no subject, is not a session.
    requiredClaims: ["exp", "sub"],
  };

  try {
    let payload;
    if (mode === "hs256") {
      if (typeof env.SUPABASE_JWT_SECRET !== "string" || env.SUPABASE_JWT_SECRET.length === 0) return null;
      ({ payload } = await jwtVerify(token, new TextEncoder().encode(env.SUPABASE_JWT_SECRET), options));
    } else {
      const url = jwksUrl(env);
      if (!url) return null;
      ({ payload } = await jwtVerify(token, remoteKeys(url), options));
    }
    // Supabase user ids are UUIDs; anything else never reaches a URL or a quota key.
    if (typeof payload.sub !== "string" || !UUID.test(payload.sub)) return null;
    return { id: payload.sub };
  } catch (error) {
    if (error instanceof AuthUnavailableError) throw error;
    return null;
  }
}
