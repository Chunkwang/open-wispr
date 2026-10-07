import type { Env } from "./types";
import { supabaseBaseUrl } from "./supabaseUrl";

const LOOPBACK_HOSTNAMES = new Set(["127.0.0.1", "localhost"]);

/** Exact match only: 0.0.0.0, 127.0.0.2, [::1] and "localhost." are NOT loopback here (fail closed). */
export function isLoopbackHostname(hostname: string): boolean {
  return LOOPBACK_HOSTNAMES.has(hostname);
}

/**
 * The placeholder JWT secret published in `.dev.vars.example`. Anyone who can
 * read this repo knows it, so a Worker verifying tokens with it would accept
 * forged sessions. A test asserts this constant matches the example file.
 */
export const EXAMPLE_JWT_SECRET = "local-dev-jwt-secret-change-me-32-chars-min";

const MIN_JWT_SECRET_LENGTH = 32;

/** Placeholder values from `.dev.vars.example` that must never run on a deployed Worker. */
const PLACEHOLDER_STRIPE_WEBHOOK_SECRET = "whsec_placeholder";
const PLACEHOLDER_STRIPE_SECRET_KEY = "sk_test_placeholder";
const PLACEHOLDER_SERVICE_ROLE_KEY = "local-dev-service-role-key";
const PLACEHOLDER_STRIPE_PRICE_ID = "price_placeholder";

export type JwtVerifyMode = "hs256" | "jwks";

/**
 * The configured verification mode: `hs256` when JWT_VERIFY_MODE is unset, else
 * exactly "hs256" or "jwks". Anything else (wrong case, empty, a typo) is null and
 * the caller must refuse to serve (500 misconfigured): a mode typo must not
 * silently fall back to a different verification path.
 */
export function jwtVerifyMode(env: Pick<Env, "JWT_VERIFY_MODE">): JwtVerifyMode | null {
  const mode = env.JWT_VERIFY_MODE;
  if (mode === undefined) return "hs256";
  return mode === "hs256" || mode === "jwks" ? mode : null;
}

/** The JWKS endpoint: SUPABASE_JWKS_URL if set, else the project's standard path. Null when it does not parse. */
export function jwksUrl(env: Pick<Env, "SUPABASE_URL" | "SUPABASE_JWKS_URL">): URL | null {
  const raw = env.SUPABASE_JWKS_URL || `${supabaseBaseUrl(env.SUPABASE_URL)}/auth/v1/.well-known/jwks.json`;
  try {
    return new URL(raw);
  } catch {
    return null;
  }
}

/**
 * True when, off loopback, jwks mode has a JWKS URL that is not https, has credentials
 * in it, or is not on the same origin as SUPABASE_URL. Keys fetched from anywhere else
 * would let whoever controls that host mint sessions. Loopback (local dev) may use
 * plain http and any host. Only meaningful in jwks mode; false otherwise.
 */
export function unsafeJwksUrlOffLoopback(
  env: Pick<Env, "JWT_VERIFY_MODE" | "SUPABASE_URL" | "SUPABASE_JWKS_URL">,
  hostname: string
): boolean {
  if (jwtVerifyMode(env) !== "jwks" || isLoopbackHostname(hostname)) return false;
  const url = jwksUrl(env);
  if (!url) return true;
  let projectOrigin: string;
  try {
    projectOrigin = new URL(supabaseBaseUrl(env.SUPABASE_URL)).origin;
  } catch {
    return true;
  }
  return url.protocol !== "https:" || url.username !== "" || url.password !== "" || url.origin !== projectOrigin;
}

/**
 * True when the Worker looks deployed (non-loopback hostname) but its JWT secret
 * is a local-dev value (the published example or anything starting `local-dev-`)
 * or too short to be a real Supabase secret. Local `wrangler dev` legitimately
 * uses these on 127.0.0.1/localhost. Applies only in hs256 mode: jwks mode holds no secret.
 */
export function unsafeJwtSecretOffLoopback(
  env: Pick<Env, "SUPABASE_JWT_SECRET" | "JWT_VERIFY_MODE">,
  hostname: string
): boolean {
  if (isLoopbackHostname(hostname)) return false;
  if (jwtVerifyMode(env) !== "hs256") return false;
  const secret = env.SUPABASE_JWT_SECRET;
  return (
    typeof secret !== "string" ||
    secret === EXAMPLE_JWT_SECRET ||
    secret.startsWith("local-dev-") ||
    secret.length < MIN_JWT_SECRET_LENGTH
  );
}

/**
 * True when any Stripe-touching route (the webhook, and POST /v1/billing/checkout and
 * /v1/billing/portal) is reached off loopback while a placeholder Stripe, price, or
 * service-role value is still configured. Shared by all three so none can be wired up
 * later without this guard, the same reasoning as authenticate()'s own guards.
 */
export function placeholderStripeConfigOffLoopback(
  env: Pick<Env, "STRIPE_WEBHOOK_SECRET" | "STRIPE_SECRET_KEY" | "STRIPE_PRICE_ID" | "SUPABASE_SERVICE_ROLE_KEY">,
  hostname: string
): boolean {
  if (isLoopbackHostname(hostname)) return false;
  return (
    env.STRIPE_WEBHOOK_SECRET === PLACEHOLDER_STRIPE_WEBHOOK_SECRET ||
    env.STRIPE_SECRET_KEY === PLACEHOLDER_STRIPE_SECRET_KEY ||
    env.STRIPE_PRICE_ID === PLACEHOLDER_STRIPE_PRICE_ID ||
    env.SUPABASE_SERVICE_ROLE_KEY === PLACEHOLDER_SERVICE_ROLE_KEY
  );
}
