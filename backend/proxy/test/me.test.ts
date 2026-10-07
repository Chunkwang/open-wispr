import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  brokenQuotaEnv,
  call,
  freezeClock,
  hangingQuotaEnv,
  installUpstream,
  makeEnv,
  mintToken,
  restoreClock,
  restoreUpstream,
  rewriteAs,
  tierReply,
  type Upstream,
} from "./helpers";
import { EXAMPLE_JWT_SECRET } from "../src/hostGuard";
import { ME_LIMITS, TIER_LIMITS } from "../src/types";

let upstream: Upstream;
beforeEach(() => {
  upstream = installUpstream();
});
afterEach(() => {
  restoreClock();
  restoreUpstream();
});

const me = (opts: Parameters<typeof call>[0] = {}) => call({ path: "/v1/me", method: "GET", ...opts });

describe("GET /v1/me", () => {
  it("rejects unauthenticated requests", async () => {
    const res = await me({ token: null });
    expect(res.status).toBe(401);
  });

  it("a Free user gets tier free and 0 remaining (rewrite is Pro-only in v1)", async () => {
    upstream.supabase = () => tierReply("free");
    const res = await me({ token: await mintToken() });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ tier: "free", remainingThisMonth: 0 });
  });

  it("a fresh Pro user gets the full monthly allowance", async () => {
    const res = await me({ token: await mintToken() });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ tier: "pro", remainingThisMonth: TIER_LIMITS.pro.perMonth });
  });

  it("remainingThisMonth reflects real consumed rewrite quota, not a static value", async () => {
    freezeClock();
    const token = await mintToken();
    for (let i = 0; i < 3; i++) {
      const { res } = await rewriteAs("hello", { token, env: makeEnv({ LLM_PROVIDER: "mock" }) });
      expect(res.status).toBe(200);
    }
    const res = await me({ token });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ tier: "pro", remainingThisMonth: TIER_LIMITS.pro.perMonth - 3 });
  });

  it("reading remaining does not itself consume any quota", async () => {
    const token = await mintToken();
    await me({ token });
    await me({ token });
    await me({ token });
    const res = await me({ token });
    expect(await res.json()).toEqual({ tier: "pro", remainingThisMonth: TIER_LIMITS.pro.perMonth });
  });

  it("a failed tier lookup is 503 service_unavailable", async () => {
    upstream.supabase = () => new Response("down", { status: 500 });
    const res = await me({ token: await mintToken() });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "service_unavailable" });
  });

  it("a broken quota store is 503 service_unavailable", async () => {
    const res = await me({ token: await mintToken(), env: brokenQuotaEnv() });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "service_unavailable" });
  });

  it("a hung quota store is cut off and answered 503", async () => {
    const started = performance.now();
    const res = await me({ token: await mintToken(), env: hangingQuotaEnv() });
    const elapsed = performance.now() - started;
    expect(res.status).toBe(503);
    expect(elapsed).toBeGreaterThanOrEqual(2500);
    expect(elapsed).toBeLessThan(6000);
  }, 10_000);

  it("refuses to serve off loopback while misconfigured, like every other authenticated route", async () => {
    const res = await me({
      host: "proxy.example.com",
      token: await mintToken({ secret: EXAMPLE_JWT_SECRET }),
      env: makeEnv({ SUPABASE_JWT_SECRET: EXAMPLE_JWT_SECRET }),
    });
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "misconfigured" });
    expect(upstream.calls).toHaveLength(0);
  });

  it("a generous number of rapid reads all succeed (well under the cap)", async () => {
    const token = await mintToken();
    const results = await Promise.all(Array.from({ length: 30 }, () => me({ token })));
    expect(results.every((r) => r.status === 200)).toBe(true);
  });

  it(`rate-limits at ${ME_LIMITS.free.perMinute} per minute, per user, on its own "me" bucket`, async () => {
    freezeClock();
    const token = await mintToken();
    const extra = 20;
    const results = await Promise.all(Array.from({ length: ME_LIMITS.free.perMinute + extra }, () => me({ token })));
    expect(results.filter((r) => r.status === 200)).toHaveLength(ME_LIMITS.free.perMinute);
    expect(results.filter((r) => r.status === 429)).toHaveLength(extra);
  });
});
