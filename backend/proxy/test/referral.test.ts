import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  SUPABASE_URL,
  call,
  freezeClock,
  installUpstream,
  jsonReply,
  makeEnv,
  mintToken,
  newUserId,
  restoreClock,
  restoreUpstream,
  type Upstream,
} from "./helpers";
import { EXAMPLE_JWT_SECRET } from "../src/hostGuard";
import { REFERRAL_LIMITS } from "../src/types";

let upstream: Upstream;
beforeEach(() => {
  upstream = installUpstream();
});
afterEach(() => {
  restoreClock();
  restoreUpstream();
});

describe("POST /v1/referral/redeem", () => {
  it("rejects unauthenticated requests", async () => {
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      json: { code: "validcode" },
    });
    expect(res.status).toBe(401);
  });

  it("rejects missing code", async () => {
    const token = await mintToken();
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token,
      json: {},
      env: makeEnv({ LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(400);
    const data = (await res.json()) as Record<string, unknown>;
    expect(data.error).toBe("missing_code");
  });

  it("rejects self-referral", async () => {
    const token = await mintToken();
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token,
      json: { code: "selfcode" },
      env: makeEnv({ LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(400);
    const data = (await res.json()) as Record<string, unknown>;
    expect(data.error).toBe("self_referral_not_allowed");
  });

  it("rejects already used code by same referee", async () => {
    const token = await mintToken();
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token,
      json: { code: "usedcode" },
      env: makeEnv({ LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(400);
    const data = (await res.json()) as Record<string, unknown>;
    expect(data.error).toBe("already_redeemed");
  });

  it("rejects unknown referral code", async () => {
    const token = await mintToken();
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token,
      json: { code: "unknowncode" },
      env: makeEnv({ LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(404);
    const data = (await res.json()) as Record<string, unknown>;
    expect(data.error).toBe("unknown_referral_code");
  });

  it("succeeds for valid referral code", async () => {
    const token = await mintToken();
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token,
      json: { code: "validcode123" },
      env: makeEnv({ LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(200);
    const data = (await res.json()) as Record<string, unknown>;
    expect(data.ok).toBe(true);
    expect(data.trial_extended).toBe(true);
  });
});

// Finding 1 (security review): /v1/referral/redeem must refuse to serve on a deployed Worker
// that is misconfigured, exactly like /v1/rewrite and /v1/edit. It goes through the same
// authenticate() as those routes, which carries the guard itself, so this proves the shared
// path actually protects this route too, and that the request never reaches referral logic.
describe("misconfiguration guard (deployed host)", () => {
  const deployed = "proxy.example.com";

  for (const [name, secret] of [
    ["the published example secret", EXAMPLE_JWT_SECRET],
    ["a short secret", "short-secret"],
  ] as const) {
    it(`refuses ${name} off loopback with 500 misconfigured, before any referral or Supabase work`, async () => {
      const res = await call({
        path: "/v1/referral/redeem",
        method: "POST",
        token: await mintToken({ secret }),
        json: { code: "validcode123" }, // a code that would otherwise succeed via the mock branch
        host: deployed,
        env: makeEnv({ SUPABASE_JWT_SECRET: secret, LLM_PROVIDER: "mock" }),
      });
      expect(res.status).toBe(500);
      expect(await res.json()).toEqual({ ok: false, error: "misconfigured" });
      // No Supabase REST call happened either: the guard is the first thing that runs.
      expect(upstream.calls).toHaveLength(0);
    });
  }

  it("still serves normally off loopback with a real-looking secret", async () => {
    const secret = "k".repeat(32);
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token: await mintToken({ secret }),
      json: { code: "validcode123" },
      host: deployed,
      env: makeEnv({ SUPABASE_JWT_SECRET: secret, LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(200);
  });
});

describe("request body cap", () => {
  it("refuses a declared Content-Length over 64 KB with 413 body_too_large, before authentication is even consulted for quota", async () => {
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token: await mintToken(),
      body: "{}",
      headers: { "content-type": "application/json", "content-length": String(64 * 1024 + 1) },
      env: makeEnv({ LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ ok: false, error: "body_too_large" });
  });

  it("refuses an oversized streamed body (no honest Content-Length) the same way", async () => {
    const big = "a".repeat(64 * 1024 + 1);
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token: await mintToken(),
      json: { code: big },
      env: makeEnv({ LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ ok: false, error: "body_too_large" });
  });
});

// Finding 2 (security review): the 8-hex-char referral code is a 32-bit space; without a
// throttle an authenticated caller could hammer /v1/referral/redeem to guess a valid code for
// free. checkAndConsumeQuota gives this route its own "referral:<userId>" Durable Object bucket
// (REFERRAL_LIMITS), separate from rewrite/edit/events, so guessing cannot borrow allowance from
// (or spend) any other counter.
describe("per-user rate limit (referral code guessing)", () => {
  it(`N rapid redemption attempts from one user: exactly ${REFERRAL_LIMITS.free.perMinute} succeed, the rest get 429 minute_limit`, async () => {
    freezeClock();
    const token = await mintToken();
    const attempt = () =>
      call({
        path: "/v1/referral/redeem",
        method: "POST",
        token,
        json: { code: "validcode123" },
        env: makeEnv({ LLM_PROVIDER: "mock" }),
      });
    const burst = 20;
    const results = await Promise.all(Array.from({ length: burst }, attempt));
    const bodies = await Promise.all(results.map((r) => r.clone().json() as Promise<Record<string, unknown>>));
    const ok = results.filter((r) => r.status === 200).length;
    const limited = results.filter((r) => r.status === 429).length;
    const other = results.filter((r) => r.status !== 200 && r.status !== 429).map((r) => r.status);
    expect({ ok, limited, other }).toEqual({ ok: REFERRAL_LIMITS.free.perMinute, limited: burst - REFERRAL_LIMITS.free.perMinute, other: [] });
    const reasons = new Set(bodies.filter((_, i) => results[i].status === 429).map((b) => b.error));
    expect([...reasons]).toEqual(["minute_limit"]);
  });

  it("a different user gets their own bucket (not shared with the burst above)", async () => {
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token: await mintToken(),
      json: { code: "validcode123" },
      env: makeEnv({ LLM_PROVIDER: "mock" }),
    });
    expect(res.status).toBe(200);
  });
});

// Finding 2 (security review): referral.ts's real (non-mock) Supabase REST path (profile lookup
// by referral_code, referrals lookup by referee_id, referrals insert) had zero coverage — only
// the LLM_PROVIDER=mock short-circuit was tested, so a broken PostgREST query string would not
// have been caught. This exercises the real fetch calls the Worker makes, against a small
// PostgREST-shaped stand-in, and asserts the exact URLs/bodies constructed.
describe("real Supabase REST path (query construction, not the mock short-circuit)", () => {
  const CODE = "abcd1234";

  function postgrest(referrerId: string, refereeHasExisting: boolean) {
    upstream.supabase = async (request) => {
      const url = new URL(request.url);
      if (url.pathname === "/rest/v1/profiles" && request.method === "GET") {
        const filter = url.searchParams.get("referral_code") ?? "";
        const code = filter.startsWith("eq.") ? decodeURIComponent(filter.slice(3)) : null;
        expect(url.searchParams.get("select")).toBe("id");
        return jsonReply(code === CODE ? [{ id: referrerId }] : []);
      }
      if (url.pathname === "/rest/v1/referrals" && request.method === "GET") {
        expect(url.searchParams.get("select")).toBe("id");
        return jsonReply(refereeHasExisting ? [{ id: "existing-row" }] : []);
      }
      if (url.pathname === "/rest/v1/referrals" && request.method === "POST") {
        return jsonReply([{ id: "new-row" }], 201);
      }
      return jsonReply({ message: `unexpected ${request.method} ${url.pathname}` }, 500);
    };
  }

  it("succeeds end to end: profile lookup, no existing redemption, insert", async () => {
    const referrerId = newUserId();
    postgrest(referrerId, false);
    const userId = newUserId();
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token: await mintToken({ sub: userId }),
      json: { code: CODE },
      env: makeEnv(),
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, referrer_id: referrerId, referee_id: userId, trial_extended: true });

    const calls = upstream.supabaseCalls();
    expect(calls[0].url).toBe(`${SUPABASE_URL}/rest/v1/profiles?referral_code=eq.${CODE}&select=id`);
    expect(calls[0].method).toBe("GET");
    expect(calls[1].url).toBe(`${SUPABASE_URL}/rest/v1/referrals?referee_id=eq.${userId}&select=id`);
    expect(calls[1].method).toBe("GET");
    expect(calls[2].url).toBe(`${SUPABASE_URL}/rest/v1/referrals`);
    expect(calls[2].method).toBe("POST");
    expect(JSON.parse(calls[2].body)).toEqual({ referrer_id: referrerId, referee_id: userId, code: CODE });
  });

  it("unknown code: 404, no referrals lookup or insert attempted", async () => {
    postgrest(newUserId(), false);
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token: await mintToken({ sub: newUserId() }),
      json: { code: "not-a-real-code" },
      env: makeEnv(),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ ok: false, error: "unknown_referral_code" });
    expect(upstream.supabaseCalls()).toHaveLength(1);
  });

  it("self-referral: the looked-up referrer id equals the caller's own id", async () => {
    const userId = newUserId();
    postgrest(userId, false);
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token: await mintToken({ sub: userId }),
      json: { code: CODE },
      env: makeEnv(),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ ok: false, error: "self_referral_not_allowed" });
    expect(upstream.supabaseCalls()).toHaveLength(1);
  });

  it("already redeemed: the referee lookup returns an existing row, no insert attempted", async () => {
    postgrest(newUserId(), true);
    const res = await call({
      path: "/v1/referral/redeem",
      method: "POST",
      token: await mintToken({ sub: newUserId() }),
      json: { code: CODE },
      env: makeEnv(),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ ok: false, error: "already_redeemed" });
    expect(upstream.supabaseCalls()).toHaveLength(2);
  });
});
