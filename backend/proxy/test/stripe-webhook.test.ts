import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  baseEnv,
  installUpstream,
  jsonReply,
  makeEnv,
  newUserId,
  postStripeWebhook,
  restoreUpstream,
  signStripeWebhook,
  stripeSubscriptionEventPayload,
  type Upstream,
} from "./helpers";

let upstream: Upstream;
beforeEach(() => {
  upstream = installUpstream();
});
afterEach(() => {
  restoreUpstream();
});

/** The exact profiles PATCH stripeWebhook.ts's setUserTier sends, asserted against upstream.supabaseCalls(). */
function tierPatchCalls() {
  return upstream.supabaseCalls().filter((c) => c.method === "PATCH" && c.url.includes("/rest/v1/profiles"));
}

describe("POST /v1/stripe/webhook: signature verification", () => {
  it("rejects a body signed with the wrong secret: 400 invalid signature, no Supabase call", async () => {
    const payload = stripeSubscriptionEventPayload("customer.subscription.created");
    const res = await postStripeWebhook(payload, { secret: "whsec_a_completely_different_secret" });
    expect(res.status).toBe(400);
    expect(await res.text()).toBe("invalid signature");
    expect(tierPatchCalls()).toHaveLength(0);
  });

  it("rejects a tampered payload (valid signature, different body): 400 invalid signature", async () => {
    const payload = stripeSubscriptionEventPayload("customer.subscription.created");
    const signature = await signStripeWebhook(payload, baseEnv.STRIPE_WEBHOOK_SECRET);
    const res = await postStripeWebhook(payload.replace('"active"', '"canceled"'), { signature });
    expect(res.status).toBe(400);
    expect(await res.text()).toBe("invalid signature");
    expect(tierPatchCalls()).toHaveLength(0);
  });

  it("accepts a correctly signed payload", async () => {
    const userId = newUserId();
    const payload = stripeSubscriptionEventPayload("customer.subscription.created", { supabaseUserId: userId, status: "active" });
    const res = await postStripeWebhook(payload);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
    expect(tierPatchCalls()).toHaveLength(1);
  });
});

describe("POST /v1/stripe/webhook: subscription status maps to tier", () => {
  // The exact mapping: active/trialing/past_due -> pro, canceled -> free. past_due stays pro
  // (tech-lead decision, see stripeWebhook.ts's doc comment): Stripe's smart-retry schedule keeps
  // trying to collect for days before the subscription actually lapses to canceled, and
  // downgrading on the first failed retry punishes the common case, not the exception.
  const cases: Array<{ status: string; tier: "free" | "pro" }> = [
    { status: "active", tier: "pro" },
    { status: "trialing", tier: "pro" },
    { status: "past_due", tier: "pro" },
    { status: "canceled", tier: "free" },
  ];

  for (const { status, tier } of cases) {
    it(`status "${status}" -> tier "${tier}"`, async () => {
      const userId = newUserId();
      const payload = stripeSubscriptionEventPayload("customer.subscription.updated", { supabaseUserId: userId, status });
      const res = await postStripeWebhook(payload);
      expect(res.status).toBe(200);
      const patches = tierPatchCalls();
      expect(patches).toHaveLength(1);
      expect(patches[0].url).toBe(`${baseEnv.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}`);
      expect(JSON.parse(patches[0].body)).toEqual({ tier });
    });
  }

  // Guards against the "keep pro through past_due" change silently widening the still-pro set:
  // canceled must remain the one status among these cases that still maps to free.
  it("canceled is the only status above that maps to free (past_due does not widen too far)", () => {
    expect(cases.filter((c) => c.tier === "free").map((c) => c.status)).toEqual(["canceled"]);
  });

  for (const type of ["customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"] as const) {
    it(`event type "${type}" is handled the same way (tier derives from status, not from the event type)`, async () => {
      const userId = newUserId();
      const payload = stripeSubscriptionEventPayload(type, { supabaseUserId: userId, status: "active" });
      const res = await postStripeWebhook(payload);
      expect(res.status).toBe(200);
      expect(JSON.parse(tierPatchCalls()[0].body)).toEqual({ tier: "pro" });
    });
  }

  it("an unhandled event type is a 200 no-op (no Supabase call)", async () => {
    const payload = JSON.stringify({ id: "evt_x", object: "event", type: "customer.created", data: { object: {} } });
    const res = await postStripeWebhook(payload);
    expect(res.status).toBe(200);
    expect(tierPatchCalls()).toHaveLength(0);
  });
});

describe("POST /v1/stripe/webhook: missing metadata.supabase_user_id", () => {
  it("answers 200 (Stripe must not retry a permanently unfixable event) but logs the anomaly, and makes no Supabase call", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const payload = stripeSubscriptionEventPayload("customer.subscription.created", { supabaseUserId: null, status: "active" });
    const res = await postStripeWebhook(payload);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
    expect(tierPatchCalls()).toHaveLength(0);
    expect(errorSpy).toHaveBeenCalledWith("stripe webhook: subscription event missing metadata.supabase_user_id, ignoring");
  });
});

describe("POST /v1/stripe/webhook: a failed Supabase write is a real 5xx (Stripe retries)", () => {
  it("the profiles PATCH failing (500) makes the webhook answer 5xx, not 200", async () => {
    upstream.supabase = () => jsonReply({ message: "mock outage" }, 500);
    const payload = stripeSubscriptionEventPayload("customer.subscription.created", { status: "active" });
    const res = await postStripeWebhook(payload);
    expect(res.status).toBeGreaterThanOrEqual(500);
    expect(res.status).toBeLessThan(600);
  });

  it("a dropped Supabase connection also makes the webhook answer 5xx, not 200", async () => {
    upstream.supabase = () => {
      throw new TypeError("network down");
    };
    const payload = stripeSubscriptionEventPayload("customer.subscription.created", { status: "active" });
    const res = await postStripeWebhook(payload);
    expect(res.status).toBeGreaterThanOrEqual(500);
    expect(res.status).toBeLessThan(600);
  });

  it("a healthy write still answers 200 (control)", async () => {
    const payload = stripeSubscriptionEventPayload("customer.subscription.created", { status: "active" });
    const res = await postStripeWebhook(payload);
    expect(res.status).toBe(200);
  });
});

describe("POST /v1/stripe/webhook: idempotency (duplicated/out-of-order delivery)", () => {
  it("the same event delivered twice produces the same PATCH both times, no error on replay", async () => {
    const userId = newUserId();
    const payload = stripeSubscriptionEventPayload("customer.subscription.created", { supabaseUserId: userId, status: "active" });
    const first = await postStripeWebhook(payload);
    const second = await postStripeWebhook(payload); // same payload -> same timestamp -> same signature is fine; Stripe does redeliver identical bodies
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    const patches = tierPatchCalls();
    expect(patches).toHaveLength(2);
    expect(JSON.parse(patches[0].body)).toEqual({ tier: "pro" });
    expect(JSON.parse(patches[1].body)).toEqual({ tier: "pro" });
  });

  it("an older event delivered after a newer one just re-applies its own status (no ordering is assumed)", async () => {
    const userId = newUserId();
    const newer = stripeSubscriptionEventPayload("customer.subscription.updated", { supabaseUserId: userId, status: "canceled" });
    const older = stripeSubscriptionEventPayload("customer.subscription.updated", { supabaseUserId: userId, status: "active" });
    await postStripeWebhook(newer);
    await postStripeWebhook(older);
    const patches = tierPatchCalls();
    expect(patches.map((p) => JSON.parse(p.body))).toEqual([{ tier: "free" }, { tier: "pro" }]);
  });
});

describe("misconfiguration guard also covers the new STRIPE_PRICE_ID placeholder", () => {
  it("refuses the placeholder STRIPE_PRICE_ID off loopback on the webhook route", async () => {
    const res = await postStripeWebhook(stripeSubscriptionEventPayload("customer.subscription.created"), {
      host: "proxy.example.com",
      env: makeEnv({ STRIPE_PRICE_ID: "price_placeholder" }),
    });
    expect(res.status).toBe(500);
    expect(await res.text()).toBe('{"error":"misconfigured"}');
  });

  it("lets the placeholder STRIPE_PRICE_ID through on loopback", async () => {
    const res = await postStripeWebhook(stripeSubscriptionEventPayload("customer.subscription.created"), {
      env: makeEnv({ STRIPE_PRICE_ID: "price_placeholder" }),
    });
    expect(res.status).toBe(200);
  });
});
