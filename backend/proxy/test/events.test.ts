import { afterEach, describe, expect, it } from "vitest";
import { call, freezeClock, makeEnv, restoreClock } from "./helpers";
import { EVENTS_LIMITS } from "../src/types";

afterEach(() => {
  restoreClock();
});

/** A fresh source per test, so bursts in one test never share a bucket with another. */
const freshIp = () => `203.0.113.${Math.floor(Math.random() * 254) + 1}`;

describe("POST /v1/events", () => {
  it("rejects non-json body", async () => {
    const res = await call({
      path: "/v1/events",
      method: "POST",
      body: "not-json",
      headers: { "content-type": "application/json" },
    });
    expect(res.status).toBe(400);
  });

  it("rejects unknown event name", async () => {
    const res = await call({
      path: "/v1/events",
      method: "POST",
      json: { event: "unknown_event_name" },
    });
    expect(res.status).toBe(400);
    const data = (await res.json()) as Record<string, unknown>;
    expect(data.error).toBe("invalid_event");
  });

  it("accepts each of the five allowed v1 event counters", async () => {
    const allowed = [
      "dictation_completed",
      "rewrite_invoked",
      "subscription_tier_changed",
      "before_after_shared",
      "referral_sent",
    ];

    for (const name of allowed) {
      const res = await call({
        path: "/v1/events",
        method: "POST",
        json: { event: name },
      });
      expect(res.status).toBe(200);
      const data = (await res.json()) as Record<string, unknown>;
      expect(data.ok).toBe(true);
      expect(data.recorded).toBe(name);
    }
  });
});

// Finding 2 (security review): /v1/events takes no auth token by design (a dictation completion
// must be countable even signed out), which otherwise makes it a free, unmetered cost/spam vector
// reachable by anyone on the internet. It now goes through the same readBodyCapped/MAX_BODY_BYTES
// cap as every other route, and is rate-limited per source (IP, or hostname when Cloudflare has
// not set one) instead of requiring the Bearer token the app already holds: requiring auth here
// would be a product change (dictation completions must count pre-sign-in), while the rate limit
// reuses the existing QuotaCounter Durable Object with zero new infrastructure.
describe("request body cap", () => {
  it("refuses a declared Content-Length over 64 KB with 413 body_too_large", async () => {
    const res = await call({
      path: "/v1/events",
      method: "POST",
      body: "{}",
      headers: { "content-type": "application/json", "content-length": String(64 * 1024 + 1), "cf-connecting-ip": freshIp() },
    });
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ ok: false, error: "body_too_large" });
  });

  it("refuses an oversized streamed body (no honest Content-Length) the same way", async () => {
    const res = await call({
      path: "/v1/events",
      method: "POST",
      json: { event: "a".repeat(64 * 1024 + 1) },
      headers: { "cf-connecting-ip": freshIp() },
    });
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ ok: false, error: "body_too_large" });
  });
});

describe("rate limit per source", () => {
  it(`N rapid requests from one IP: exactly ${EVENTS_LIMITS.free.perMinute} succeed, the rest get 429 minute_limit`, async () => {
    freezeClock();
    const ip = freshIp();
    const attempt = () =>
      call({
        path: "/v1/events",
        method: "POST",
        json: { event: "dictation_completed" },
        headers: { "cf-connecting-ip": ip },
      });
    const burst = EVENTS_LIMITS.free.perMinute + 15;
    const results = await Promise.all(Array.from({ length: burst }, attempt));
    const bodies = await Promise.all(results.map((r) => r.clone().json() as Promise<Record<string, unknown>>));
    const ok = results.filter((r) => r.status === 200).length;
    const limited = results.filter((r) => r.status === 429).length;
    const other = results.filter((r) => r.status !== 200 && r.status !== 429).map((r) => r.status);
    expect({ ok, limited, other }).toEqual({ ok: EVENTS_LIMITS.free.perMinute, limited: burst - EVENTS_LIMITS.free.perMinute, other: [] });
    const reasons = new Set(bodies.filter((_, i) => results[i].status === 429).map((b) => b.error));
    expect([...reasons]).toEqual(["minute_limit"]);
  });

  it("a different IP gets its own bucket", async () => {
    const res = await call({
      path: "/v1/events",
      method: "POST",
      json: { event: "dictation_completed" },
      headers: { "cf-connecting-ip": freshIp() },
    });
    expect(res.status).toBe(200);
  });

  it("falls back to a hostname-keyed bucket when no cf-connecting-ip header is present (two hostnames do not share it)", async () => {
    const res = await call({
      path: "/v1/events",
      method: "POST",
      json: { event: "dictation_completed" },
      host: `no-ip-header-${Math.random().toString(36).slice(2, 10)}.example.com`,
    });
    expect(res.status).toBe(200);
  });
});
