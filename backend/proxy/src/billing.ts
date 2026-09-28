import type Stripe from "stripe";
import type { Env, Tier } from "./types";
import { AuthUnavailableError, MisconfiguredError, authenticate, type AuthedUser } from "./auth";
import { checkAndConsumeQuota, type RateLimitResult } from "./rateLimit";
import { getUserTier } from "./tier";
import { stripeClient } from "./stripeClient";
import { supabaseBaseUrl } from "./supabaseUrl";

/**
 * POST /v1/billing/checkout and POST /v1/billing/portal (task 4.2, 4.4).
 *
 * Both are reachable by Free users on purpose: checkout is how a Free user becomes Pro, so it
 * cannot be gated on the Pro tier the way /v1/rewrite and /v1/edit are. Checkout does short-circuit
 * an already-Pro caller (see the tier check in handleBillingCheckout) so it cannot start a second,
 * unwanted subscription. Both go through
 * authenticate() (so a misconfigured deploy refuses to serve them exactly like every other
 * route), a shared per-user rate limit (own "billing" Durable Object bucket, not shared with
 * rewrite/edit/referral/events — creating Stripe sessions is a real, metered call against
 * Stripe's API, mock or not, and an authenticated caller must not be able to hammer it for
 * free), and the same placeholder-config guard the webhook uses (placeholderStripeConfigOffLoopback
 * in hostGuard.ts, checked by index.ts before either handler runs).
 *
 * Neither endpoint takes a request body: there is exactly one Pro plan in v1 (STRIPE_PRICE_ID),
 * so there is nothing for the caller to choose.
 */

const CHECKOUT_FALLBACK_SUCCESS_URL = "https://example.com/billing/success"; // placeholder until the app has a real domain (D1)
const CHECKOUT_FALLBACK_CANCEL_URL = "https://example.com/billing/cancel";
const PORTAL_FALLBACK_RETURN_URL = "https://example.com/billing/portal-return";

type BillingResponse = { url: string } | { error: string };

function json(body: BillingResponse, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/** Runs authenticate() and the shared "billing" quota check. Returns the user, or the response to answer with. */
async function authenticateAndThrottle(request: Request, env: Env, hostname: string): Promise<{ user: AuthedUser } | { response: Response }> {
  let user: AuthedUser | null;
  try {
    user = await authenticate(request, env, hostname);
  } catch (error) {
    if (error instanceof MisconfiguredError) {
      console.error(`misconfigured: ${error.reason}`);
      return { response: json({ error: "misconfigured" }, 500) };
    }
    if (error instanceof AuthUnavailableError) {
      return { response: json({ error: "service_unavailable" }, 503) };
    }
    throw error;
  }
  if (!user) return { response: json({ error: "unauthorized" }, 401) };

  // Same reasoning as referral.ts's own throttle: checked before any Supabase or Stripe call, and
  // keyed on a fixed tier since BILLING_LIMITS is identical for both, so no tier lookup is needed
  // just to decide whether to serve the request at all.
  let quota: RateLimitResult;
  try {
    quota = await checkAndConsumeQuota(user.id, "free", env, "billing");
  } catch {
    return { response: json({ error: "service_unavailable" }, 503) };
  }
  if (!quota.allowed) return { response: json({ error: quota.reason }, 429) };

  return { user };
}

export async function handleBillingCheckout(request: Request, env: Env, hostname: string): Promise<Response> {
  const gate = await authenticateAndThrottle(request, env, hostname);
  if ("response" in gate) return gate.response;
  const { user } = gate;

  // Short-circuit an already-Pro caller instead of starting a second subscription with no
  // warning. This reads profiles.tier, which the webhook (stripeWebhook.ts) sets from the
  // subscription's own metadata.supabase_user_id — independent of profiles.stripe_customer_id —
  // so it also catches the common shape of the "prior checkout's stripe_customer_id save
  // silently failed" case (see the catch below) once that earlier subscription's webhook has
  // landed. KNOWN GAP, not solved here: a genuine race (two concurrent checkout calls before
  // either webhook lands, or a webhook delivery that is delayed or still pending) can still let a
  // second Stripe customer/session through and is not closed by this tier check. Closing it fully
  // would mean searching Stripe for an existing active subscription on this Supabase user before
  // creating a session, not just trusting our own profiles.tier column. Per security-engineer's
  // report this is a self-inflicted double-charge risk for one user, not a cross-user security
  // boundary, so it is flagged here as low-priority rather than solved now.
  let tier: Tier;
  try {
    tier = await getUserTier(user.id, env);
  } catch {
    return json({ error: "service_unavailable" }, 503);
  }
  if (tier === "pro") return json({ error: "already_pro" }, 409);

  const stripe = stripeClient(env, hostname);

  let customerId: string;
  try {
    const existing = await getStripeCustomerId(user.id, env);
    if (existing) {
      customerId = existing;
    } else {
      const customer = await stripe.customers.create({ metadata: { supabase_user_id: user.id } });
      customerId = customer.id;
      // Best-effort save. If this write fails we still hand back a working checkout URL — the
      // user must not be blocked from paying because of a profile write flaking — but portal
      // lookups depend on this column, so a persistent failure here needs the same operational
      // attention as any other failed Supabase write. Logged content-free, like every other
      // catch in this file: no user id, no Stripe id.
      try {
        await setStripeCustomerId(user.id, customerId, env);
      } catch {
        console.error("billing: failed to save stripe_customer_id after creating a new Stripe customer");
      }
    }
  } catch {
    return json({ error: "service_unavailable" }, 503);
  }

  let session: Stripe.Checkout.Session;
  try {
    session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      line_items: [{ price: env.STRIPE_PRICE_ID, quantity: 1 }],
      // The webhook (stripeWebhook.ts) reads this exact field to know which Supabase row to
      // flip to pro. Do not rename it without updating that handler too.
      subscription_data: { metadata: { supabase_user_id: user.id } },
      success_url: env.BILLING_SUCCESS_URL || CHECKOUT_FALLBACK_SUCCESS_URL,
      cancel_url: env.BILLING_CANCEL_URL || CHECKOUT_FALLBACK_CANCEL_URL,
    });
  } catch {
    return json({ error: "checkout_failed" }, 502);
  }
  if (!session.url) return json({ error: "checkout_failed" }, 502);
  return json({ url: session.url }, 200);
}

export async function handleBillingPortal(request: Request, env: Env, hostname: string): Promise<Response> {
  const gate = await authenticateAndThrottle(request, env, hostname);
  if ("response" in gate) return gate.response;
  const { user } = gate;

  let customerId: string | null;
  try {
    customerId = await getStripeCustomerId(user.id, env);
  } catch {
    return json({ error: "service_unavailable" }, 503);
  }
  if (!customerId) return json({ error: "no_customer" }, 404);

  const stripe = stripeClient(env, hostname);
  let session: Stripe.BillingPortal.Session;
  try {
    session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: env.BILLING_PORTAL_RETURN_URL || PORTAL_FALLBACK_RETURN_URL,
    });
  } catch {
    return json({ error: "portal_failed" }, 502);
  }
  return json({ url: session.url }, 200);
}

/** GET profiles.stripe_customer_id via PostgREST. Null when the row has none set yet. Throws on any failure. */
async function getStripeCustomerId(userId: string, env: Env): Promise<string | null> {
  const url = `${supabaseBaseUrl(env.SUPABASE_URL)}/rest/v1/profiles?id=eq.${encodeURIComponent(userId)}&select=stripe_customer_id`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    },
    signal: AbortSignal.timeout(3000),
  });
  if (!res.ok) throw new Error(`profiles lookup failed: ${res.status}`);
  const rows = (await res.json()) as unknown;
  if (!Array.isArray(rows)) throw new Error("profiles lookup: unexpected response shape");
  const value = (rows[0] as { stripe_customer_id?: unknown } | undefined)?.stripe_customer_id;
  return typeof value === "string" && value.length > 0 ? value : null;
}

/** PATCH profiles.stripe_customer_id via PostgREST, same pattern as stripeWebhook.ts's setUserTier. */
async function setStripeCustomerId(userId: string, customerId: string, env: Env): Promise<void> {
  const res = await fetch(`${supabaseBaseUrl(env.SUPABASE_URL)}/rest/v1/profiles?id=eq.${encodeURIComponent(userId)}`, {
    method: "PATCH",
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({ stripe_customer_id: customerId }),
    signal: AbortSignal.timeout(3000),
  });
  if (!res.ok) throw new Error(`profiles update failed: ${res.status}`);
}
