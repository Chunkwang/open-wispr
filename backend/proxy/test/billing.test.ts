import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { baseEnv, call, freezeClock, installUpstream, jsonReply, makeEnv, mintToken, newUserId, restoreClock, restoreUpstream, tierReply, type Upstream } from "./helpers";
import { BILLING_LIMITS } from "../src/types";

let upstream: Upstream;
beforeEach(() => {
  upstream = installUpstream();
});
afterEach(() => {
  restoreClock();
  restoreUpstream();
});

const checkout = (opts: Parameters<typeof call>[0] = {}) => call({ path: "/v1/billing/checkout", method: "POST", ...opts });
const portal = (opts: Parameters<typeof call>[0] = {}) => call({ path: "/v1/billing/portal", method: "POST", ...opts });

/** No stripe_customer_id on file yet (the common starting state). */
function profilesWithNoCustomer(patchedIds: string[] = []) {
  upstream.supabase = async (request) => {
    const url = new URL(request.url);
    if (url.pathname === "/rest/v1/profiles" && request.method === "GET") return jsonReply([{ stripe_customer_id: null }]);
    if (url.pathname === "/rest/v1/profiles" && request.method === "PATCH") {
      patchedIds.push(url.searchParams.get("id") ?? "");
      return new Response(null, { status: 204 });
    }
    return jsonReply({ message: `unexpected ${request.method} ${url.pathname}` }, 500);
  };
}

/** Already has a saved stripe_customer_id. */
function profilesWithCustomer(customerId: string) {
  upstream.supabase = async (request) => {
    const url = new URL(request.url);
    if (url.pathname === "/rest/v1/profiles" && request.method === "GET") return jsonReply([{ stripe_customer_id: customerId }]);
    return jsonReply({ message: `unexpected ${request.method} ${url.pathname}` }, 500);
  };
}

describe("POST /v1/billing/checkout", () => {
  it("rejects unauthenticated requests", async () => {
    const res = await checkout({ token: null });
    expect(res.status).toBe(401);
  });

  it("Free-tier users can reach it (checkout is how they become Pro; not tier-gated)", async () => {
    upstream.supabase = () => tierReply("free");
    profilesWithNoCustomer();
    const res = await checkout({ token: await mintToken() });
    expect(res.status).toBe(200);
  });

  it("short-circuits an already-Pro caller with already_pro: no Stripe customer or session created", async () => {
    upstream.supabase = () => tierReply("pro");
    const res = await checkout({ token: await mintToken() });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "already_pro" });
    expect(upstream.stripeCalls()).toHaveLength(0);
  });

  it("creates a new Stripe customer, saves it to the profile, and returns the Checkout Session url", async () => {
    const userId = newUserId();
    const patched: string[] = [];
    profilesWithNoCustomer(patched);
    const res = await checkout({ token: await mintToken({ sub: userId }) });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: "https://checkout.stripe.com/test-session" });

    const stripeCalls = upstream.stripeCalls();
    const customerCall = stripeCalls.find((c) => new URL(c.url).pathname === "/v1/customers");
    expect(customerCall?.method).toBe("POST");
    expect(new URLSearchParams(customerCall!.body).get("metadata[supabase_user_id]")).toBe(userId);

    const sessionCall = stripeCalls.find((c) => new URL(c.url).pathname === "/v1/checkout/sessions");
    const form = new URLSearchParams(sessionCall!.body);
    expect(form.get("mode")).toBe("subscription");
    expect(form.get("customer")).toBe("cus_test");
    expect(form.get("line_items[0][price]")).toBe(baseEnv.STRIPE_PRICE_ID);
    // The webhook depends on this exact field name to know which Supabase row to flip.
    expect(form.get("subscription_data[metadata][supabase_user_id]")).toBe(userId);

    expect(patched).toEqual([`eq.${userId}`]); // the new customer id was saved
  });

  it("reuses an existing stripe_customer_id: no new customer created, no profile PATCH", async () => {
    profilesWithCustomer("cus_existing_123");
    const res = await checkout({ token: await mintToken() });
    expect(res.status).toBe(200);
    const stripeCalls = upstream.stripeCalls();
    expect(stripeCalls.some((c) => new URL(c.url).pathname === "/v1/customers")).toBe(false);
    const sessionCall = stripeCalls.find((c) => new URL(c.url).pathname === "/v1/checkout/sessions");
    expect(new URLSearchParams(sessionCall!.body).get("customer")).toBe("cus_existing_123");
    expect(upstream.supabaseCalls().some((c) => c.method === "PATCH")).toBe(false);
  });

  it("still returns a working checkout url even when saving the new stripe_customer_id fails (best-effort, logged)", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    upstream.supabase = async (request) => {
      const url = new URL(request.url);
      if (url.pathname === "/rest/v1/profiles" && request.method === "GET") return jsonReply([{ stripe_customer_id: null }]);
      if (url.pathname === "/rest/v1/profiles" && request.method === "PATCH") return jsonReply({ message: "down" }, 500);
      return jsonReply({ message: "unexpected" }, 500);
    };
    const res = await checkout({ token: await mintToken() });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: "https://checkout.stripe.com/test-session" });
    expect(errorSpy).toHaveBeenCalledWith("billing: failed to save stripe_customer_id after creating a new Stripe customer");
  });

  it("a failed Supabase profile lookup is 503 service_unavailable", async () => {
    upstream.supabase = () => jsonReply({ message: "down" }, 500);
    const res = await checkout({ token: await mintToken() });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "service_unavailable" });
  });

  it("a failed Stripe customer creation is 503 service_unavailable", async () => {
    profilesWithNoCustomer();
    upstream.stripe = () => jsonReply({ error: { message: "down" } }, 500);
    const res = await checkout({ token: await mintToken() });
    expect(res.status).toBe(503);
  });

  it("a failed Checkout Session creation is 502 checkout_failed", async () => {
    profilesWithCustomer("cus_existing");
    upstream.stripe = (request) => {
      if (new URL(request.url).pathname === "/v1/checkout/sessions") return jsonReply({ error: { message: "down" } }, 500);
      return jsonReply({ id: "cus_existing", object: "customer" });
    };
    const res = await checkout({ token: await mintToken() });
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "checkout_failed" });
  });

  it("a Checkout Session with no url is 502 checkout_failed", async () => {
    profilesWithCustomer("cus_existing");
    upstream.stripe = (request) => {
      if (new URL(request.url).pathname === "/v1/checkout/sessions") return jsonReply({ id: "cs_no_url", object: "checkout.session" });
      return jsonReply({ id: "cus_existing", object: "customer" });
    };
    const res = await checkout({ token: await mintToken() });
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "checkout_failed" });
  });

  it(`rate-limits at ${BILLING_LIMITS.free.perMinute} per minute, per user`, async () => {
    freezeClock();
    profilesWithCustomer("cus_existing");
    const token = await mintToken();
    const results = await Promise.all(Array.from({ length: 20 }, () => checkout({ token })));
    expect(results.filter((r) => r.status === 200)).toHaveLength(BILLING_LIMITS.free.perMinute);
    expect(results.filter((r) => r.status === 429)).toHaveLength(20 - BILLING_LIMITS.free.perMinute);
  });
});

describe("POST /v1/billing/portal", () => {
  it("rejects unauthenticated requests", async () => {
    const res = await portal({ token: null });
    expect(res.status).toBe(401);
  });

  it("404s with no_customer when the profile has no stripe_customer_id yet", async () => {
    profilesWithNoCustomer();
    const res = await portal({ token: await mintToken() });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "no_customer" });
  });

  it("returns a portal url for an existing customer", async () => {
    profilesWithCustomer("cus_abc");
    const res = await portal({ token: await mintToken() });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: "https://billing.stripe.com/test-session" });
    const sessionCall = upstream.stripeCalls().find((c) => new URL(c.url).pathname === "/v1/billing_portal/sessions");
    expect(new URLSearchParams(sessionCall!.body).get("customer")).toBe("cus_abc");
  });

  it("a failed portal session creation is 502 portal_failed", async () => {
    profilesWithCustomer("cus_abc");
    upstream.stripe = () => jsonReply({ error: { message: "down" } }, 500);
    const res = await portal({ token: await mintToken() });
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "portal_failed" });
  });

  it("a failed Supabase lookup is 503 service_unavailable", async () => {
    upstream.supabase = () => jsonReply({ message: "down" }, 500);
    const res = await portal({ token: await mintToken() });
    expect(res.status).toBe(503);
  });

  it("shares the same per-user rate-limit bucket as checkout", async () => {
    freezeClock();
    profilesWithCustomer("cus_abc");
    const token = await mintToken();
    await Promise.all(Array.from({ length: BILLING_LIMITS.free.perMinute }, () => checkout({ token })));
    const res = await portal({ token });
    expect(res.status).toBe(429);
  });
});

describe("misconfiguration guard (deployed host) also applies to /v1/billing/*", () => {
  const deployed = "proxy.example.com";

  it("refuses checkout off loopback while STRIPE_PRICE_ID is still the placeholder", async () => {
    const secret = "k".repeat(32);
    const res = await checkout({
      host: deployed,
      token: await mintToken({ secret }),
      env: makeEnv({ SUPABASE_JWT_SECRET: secret, STRIPE_PRICE_ID: "price_placeholder" }),
    });
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "misconfigured" });
    expect(upstream.calls).toHaveLength(0);
  });

  it("refuses portal off loopback while STRIPE_SECRET_KEY is still the placeholder", async () => {
    const secret = "k".repeat(32);
    const res = await portal({
      host: deployed,
      token: await mintToken({ secret }),
      env: makeEnv({ SUPABASE_JWT_SECRET: secret, STRIPE_SECRET_KEY: "sk_test_placeholder" }),
    });
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "misconfigured" });
  });
});
