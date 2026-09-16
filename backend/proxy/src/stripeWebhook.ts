import Stripe from "stripe";
import type { Env } from "./types";

/**
 * Requires the Checkout Session (or the subscription itself) to carry
 * `metadata.supabase_user_id` — set that when creating the Checkout Session
 * client/server-side, or this handler has no way to know which Supabase
 * row to update.
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
      if (!userId) break;
      const tier = subscription.status === "active" || subscription.status === "trialing" ? "pro" : "free";
      await setUserTier(userId, tier, env);
      break;
    }
  }

  return new Response("ok", { status: 200 });
}

async function setUserTier(userId: string, tier: "free" | "pro", env: Env): Promise<void> {
  await fetch(`${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}`, {
    method: "PATCH",
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({ tier }),
  });
}
