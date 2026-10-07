import Stripe from "stripe";
import type { Env } from "./types";
import { supabaseBaseUrl } from "./supabaseUrl";

/**
 * Requires the Checkout Session (or the subscription itself) to carry
 * `metadata.supabase_user_id` — set that when creating the Checkout Session
 * client/server-side (see billing.ts), or this handler has no way to know
 * which Supabase row to update.
 *
 * Tier is derived from the subscription's CURRENT status on the event, never from the event's
 * `type`: created/updated/deleted are handled identically, so a duplicated or out-of-order
 * delivery (Stripe makes no ordering guarantee) just re-applies the same mapping and is
 * idempotent — replaying the same event twice has the same effect as once.
 *
 * `past_due` maps to "pro", not "free" (see the ternary below). tech-lead decision: a single
 * failed charge is the common case, not the exception, and Stripe's smart-retry schedule keeps
 * trying to collect for days before the subscription actually lapses. Downgrading the user the
 * instant the first retry fails punishes them before Stripe itself has given up, which is worse
 * than necessary. Only `canceled` (and any other status that isn't active/trialing/past_due,
 * e.g. `unpaid` or `incomplete_expired`) maps to "free".
 */
export async function handleStripeWebhook(request: Request, env: Env): Promise<Response> {
  const stripe = new Stripe(env.STRIPE_SECRET_KEY, {
    httpClient: Stripe.createFetchHttpClient(),
  });

  const signature = request.headers.get("stripe-signature");
  const body = await request.text();
  if (!signature) return new Response("missing signature", { status: 400 });

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      env.STRIPE_WEBHOOK_SECRET,
      undefined,
      Stripe.createSubtleCryptoProvider()
    );
  } catch {
    return new Response("invalid signature", { status: 400 });
  }

  switch (event.type) {
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const subscription = event.data.object as Stripe.Subscription;
      const userId = subscription.metadata.supabase_user_id;
      if (!userId) {
        // Not a transient failure — this event will never carry the field, so retrying it for
        // up to 3 days (Stripe's retry window) cannot fix anything and only pointlessly repeats
        // the same no-op. Answering 200 tells Stripe not to retry, but the anomaly is still
        // logged (content-free: no ids, no subscription details) so it is visible in Worker
        // logs rather than silently vanishing — most likely cause is a subscription created
        // outside billing.ts's Checkout Session (e.g. by hand in the Stripe dashboard).
        console.error("stripe webhook: subscription event missing metadata.supabase_user_id, ignoring");
        break;
      }
      const tier =
        subscription.status === "active" || subscription.status === "trialing" || subscription.status === "past_due"
          ? "pro"
          : "free";
      try {
        await setUserTier(userId, tier, env);
      } catch {
        // A failed Supabase write must come back as a real 5xx: Stripe only retries on a
        // non-2xx response, and a 200 here would leave a paying customer stuck on Free with no
        // second chance. No upstream detail in the body or logged — same discipline as every
        // other outage path in this proxy (tier.ts, rateLimit.ts).
        return new Response("tier update failed", { status: 502 });
      }
      break;
    }
  }

  return new Response("ok", { status: 200 });
}

async function setUserTier(userId: string, tier: "free" | "pro", env: Env): Promise<void> {
  const res = await fetch(`${supabaseBaseUrl(env.SUPABASE_URL)}/rest/v1/profiles?id=eq.${encodeURIComponent(userId)}`, {
    method: "PATCH",
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({ tier }),
  });
  if (!res.ok) throw new Error(`profiles update failed: ${res.status}`);
}
