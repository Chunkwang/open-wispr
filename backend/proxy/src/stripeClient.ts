import Stripe from "stripe";
import type { Env } from "./types";
import { isLoopbackHostname } from "./hostGuard";

/**
 * Builds the Stripe SDK client used for outbound calls (customer, Checkout Session and billing
 * portal Session creation — see billing.ts). Points at the real API by default.
 *
 * Only on a loopback hostname, and only when STRIPE_API_BASE_URL is set (dev only, e.g.
 * `http://127.0.0.1:54323` for `scripts/mock-stripe.mjs`), is the client redirected there instead
 * of api.stripe.com, via the `host`/`protocol`/`port` config the Stripe Node SDK (v17) has carried
 * since its early versions for exactly this purpose (pointing the client at a non-default host).
 * STRIPE_API_BASE_URL is never honored off loopback, even if somehow set on a deployed Worker —
 * the same fail-closed treatment hostGuard.ts gives the Supabase JWKS URL, so a stray dev value
 * left in production config cannot silently redirect real Stripe traffic anywhere.
 *
 * A malformed override falls back to the real API rather than throwing on every call: a typo in
 * a local .dev.vars should break checkout obviously (wrong host, connection refused), not crash
 * unrelated requests.
 */
export function stripeClient(env: Pick<Env, "STRIPE_SECRET_KEY" | "STRIPE_API_BASE_URL">, hostname: string): Stripe {
  const config: Stripe.StripeConfig = { httpClient: Stripe.createFetchHttpClient() };
  if (isLoopbackHostname(hostname) && env.STRIPE_API_BASE_URL) {
    try {
      const url = new URL(env.STRIPE_API_BASE_URL);
      config.host = url.hostname;
      config.protocol = url.protocol === "http:" ? "http" : "https";
      if (url.port) config.port = Number(url.port);
    } catch {
      // Malformed STRIPE_API_BASE_URL: fall through to the default (real API) config.
    }
  }
  return new Stripe(env.STRIPE_SECRET_KEY, config);
}
