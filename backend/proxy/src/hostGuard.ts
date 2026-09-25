import type { Env } from "./types";

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

/**
 * True when the Worker looks deployed (non-loopback hostname) but its JWT secret
 * is a local-dev value (the published example or anything starting `local-dev-`)
 * or too short to be a real Supabase secret. Local `wrangler dev` legitimately
 * uses these on 127.0.0.1/localhost.
 */
export function unsafeJwtSecretOffLoopback(env: Pick<Env, "SUPABASE_JWT_SECRET">, hostname: string): boolean {
  if (isLoopbackHostname(hostname)) return false;
  const secret = env.SUPABASE_JWT_SECRET;
  return (
    typeof secret !== "string" ||
    secret === EXAMPLE_JWT_SECRET ||
    secret.startsWith("local-dev-") ||
    secret.length < MIN_JWT_SECRET_LENGTH
  );
}

/** True when the webhook route is reached off loopback while a placeholder Stripe or service-role value is configured. */
export function placeholderWebhookConfigOffLoopback(
  env: Pick<Env, "STRIPE_WEBHOOK_SECRET" | "STRIPE_SECRET_KEY" | "SUPABASE_SERVICE_ROLE_KEY">,
  hostname: string
): boolean {
  if (isLoopbackHostname(hostname)) return false;
  return (
    env.STRIPE_WEBHOOK_SECRET === PLACEHOLDER_STRIPE_WEBHOOK_SECRET ||
    env.STRIPE_SECRET_KEY === PLACEHOLDER_STRIPE_SECRET_KEY ||
    env.SUPABASE_SERVICE_ROLE_KEY === PLACEHOLDER_SERVICE_ROLE_KEY
  );
}
