import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  ANTHROPIC_URL,
  ISSUER,
  JWT_SECRET,
  SUPABASE_URL,
  baseEnv,
  brokenQuotaEnv,
  call,
  claudeReply,
  entrypoint,
  freezeClock,
  hang,
  installUpstream,
  jsonReply,
  makeEnv,
  mintToken,
  newUserId,
  restoreClock,
  restoreUpstream,
  rewriteAs,
  tierReply,
  type Upstream,
} from "./helpers";
import { EXAMPLE_JWT_SECRET } from "../src/hostGuard";

let upstream: Upstream;
beforeEach(() => {
  upstream = installUpstream();
});
afterEach(() => {
  restoreClock();
  restoreUpstream();
});

/** A string of exactly n characters. */
const text = (n: number) => "a".repeat(n);

const b64url = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");

async function expectError(res: Response, status: number, error: string) {
  expect(res.status).toBe(status);
  expect(res.headers.get("content-type")).toContain("application/json");
  expect(await res.json()).toEqual({ error });
}

describe("routing", () => {
  it("returns 404 for unknown routes and wrong methods", async () => {
    expect((await call({ path: "/nope" })).status).toBe(404);
    expect((await call({ path: "/v1/rewrite", method: "GET" })).status).toBe(404);
    expect((await call({ path: "/", method: "GET" })).status).toBe(404);
    expect(upstream.calls).toHaveLength(0);
  });

  it("serves through the real entrypoint (bundled Worker)", async () => {
    const notFound = await entrypoint.fetch(new Request("http://localhost/nope"));
    expect(notFound.status).toBe(404);
    const noAuth = await entrypoint.fetch(new Request("http://localhost/v1/rewrite", { method: "POST", body: "{}" }));
    await expectError(noAuth, 401, "unauthorized");
  });
});

describe("authentication (401)", () => {
  const goodBody = { transcript: "send it tomorrow" };

  async function expectUnauthorized(res: Response) {
    await expectError(res, 401, "unauthorized");
    // Rejected before any tier lookup, quota use or provider call.
    expect(upstream.calls).toHaveLength(0);
  }

  it("rejects a missing Authorization header", async () => {
    await expectUnauthorized(await call({ json: goodBody }));
  });

  it("rejects a non-Bearer scheme and an empty bearer", async () => {
    await expectUnauthorized(await call({ authorization: "Basic dXNlcjpwYXNz", json: goodBody }));
    await expectUnauthorized(await call({ authorization: "Bearer ", json: goodBody }));
    await expectUnauthorized(await call({ authorization: "bearer lowercase", json: goodBody }));
  });

  it("rejects a malformed token", async () => {
    await expectUnauthorized(await call({ token: "not-a-jwt", json: goodBody }));
    await expectUnauthorized(await call({ token: "a.b.c", json: goodBody }));
  });

  it("rejects a tampered token (payload changed, signature kept)", async () => {
    const token = await mintToken({ sub: newUserId() });
    const [header, , signature] = token.split(".");
    const forgedPayload = b64url({
      sub: newUserId(),
      aud: "authenticated",
      iss: ISSUER,
      exp: Math.floor(Date.now() / 1000) + 3600,
    });
    await expectUnauthorized(await call({ token: `${header}.${forgedPayload}.${signature}`, json: goodBody }));
  });

  it("rejects an expired token", async () => {
    await expectUnauthorized(await call({ token: await mintToken({ expiresIn: -60 }), json: goodBody }));
  });

  it("rejects a token signed with the wrong secret", async () => {
    const token = await mintToken({ secret: "local-dev-some-other-secret-value-xx" });
    await expectUnauthorized(await call({ token, json: goodBody }));
  });

  it("rejects a token with the wrong algorithm (HS512 with the right secret)", async () => {
    await expectUnauthorized(await call({ token: await mintToken({ alg: "HS512" }), json: goodBody }));
  });

  it("rejects an unsigned alg=none token", async () => {
    const token = `${b64url({ alg: "none", typ: "JWT" })}.${b64url({
      sub: newUserId(),
      aud: "authenticated",
      iss: ISSUER,
      exp: Math.floor(Date.now() / 1000) + 3600,
    })}.`;
    await expectUnauthorized(await call({ token, json: goodBody }));
  });

  it("rejects the wrong audience, a missing audience, and an audience list without 'authenticated'", async () => {
    await expectUnauthorized(await call({ token: await mintToken({ aud: "anon" }), json: goodBody }));
    await expectUnauthorized(await call({ token: await mintToken({ aud: "service_role" }), json: goodBody }));
    await expectUnauthorized(await call({ token: await mintToken({ aud: null }), json: goodBody }));
    await expectUnauthorized(await call({ token: await mintToken({ aud: ["anon", "other"] }), json: goodBody }));
  });

  it("rejects the wrong issuer, another project's issuer, and a missing issuer", async () => {
    await expectUnauthorized(await call({ token: await mintToken({ iss: "https://evil.example/auth/v1" }), json: goodBody }));
    await expectUnauthorized(
      await call({ token: await mintToken({ iss: "https://other-project.supabase.test/auth/v1" }), json: goodBody })
    );
    await expectUnauthorized(await call({ token: await mintToken({ iss: SUPABASE_URL }), json: goodBody }));
    await expectUnauthorized(await call({ token: await mintToken({ iss: null }), json: goodBody }));
  });

  it("rejects a token with no subject", async () => {
    await expectUnauthorized(await call({ token: await mintToken({ sub: null }), json: goodBody }));
  });

  it("accepts a valid token, and tolerates a trailing slash on SUPABASE_URL", async () => {
    upstream.anthropic = () => claudeReply("Send it tomorrow.");
    const ok = await rewriteAs("send it tomorrow");
    expect(ok.res.status).toBe(200);
    const slash = await rewriteAs("send it tomorrow", { env: makeEnv({ SUPABASE_URL: `${SUPABASE_URL}/` }) });
    expect(slash.res.status).toBe(200);
  });

  it("fails closed when SUPABASE_URL is empty (no issuer to compare against)", async () => {
    const { res } = await rewriteAs("send it tomorrow", { env: makeEnv({ SUPABASE_URL: "" }) });
    await expectError(res, 401, "unauthorized");
  });
});

describe("tier (402)", () => {
  it("returns 402 for a free user and never calls the provider", async () => {
    upstream.supabase = () => tierReply("free");
    const { res } = await rewriteAs("hello there");
    await expectError(res, 402, "rewrite requires the Pro tier");
    expect(upstream.anthropicCalls()).toHaveLength(0);
  });

  it("returns 402 (not 200) for a free user even with the mock LLM on", async () => {
    upstream.supabase = () => tierReply("free");
    const { res } = await rewriteAs("hello there", { env: makeEnv({ LLM_PROVIDER: "mock" }) });
    await expectError(res, 402, "rewrite requires the Pro tier");
  });

  it("returns 402 for an unknown user (no profile row)", async () => {
    upstream.supabase = () => tierReply(null);
    const { res } = await rewriteAs("hello there");
    await expectError(res, 402, "rewrite requires the Pro tier");
    expect(upstream.anthropicCalls()).toHaveLength(0);
  });

  it("returns 402 for any tier value other than 'pro'", async () => {
    upstream.supabase = () => tierReply("enterprise");
    const { res } = await rewriteAs("hello there");
    expect(res.status).toBe(402);
  });

  it("looks the tier up for the token's user with the service-role key", async () => {
    const { userId } = await rewriteAs("hello there");
    const [lookup] = upstream.supabaseCalls();
    expect(lookup.url).toContain(`/rest/v1/profiles?id=eq.${userId}`);
    expect(lookup.headers.get("apikey")).toBe(baseEnv.SUPABASE_SERVICE_ROLE_KEY);
  });
});

describe("per-minute quota (429)", () => {
  it("allows 5 requests per minute then answers 429 minute_limit, without calling the provider", async () => {
    freezeClock(); // no window boundary can fall inside this test
    const token = await mintToken({ sub: newUserId() });
    for (let i = 0; i < 5; i++) {
      const res = await call({ token, json: { transcript: `note ${i}` } });
      expect(res.status, `request ${i + 1}`).toBe(200);
    }
    expect(upstream.anthropicCalls()).toHaveLength(5);

    const sixth = await call({ token, json: { transcript: "note 6" } });
    await expectError(sixth, 429, "minute_limit");
    expect(upstream.anthropicCalls()).toHaveLength(5);
  });

  it("keeps quotas per user", async () => {
    freezeClock(); // no window boundary can fall inside this test
    const a = await mintToken({ sub: newUserId() });
    for (let i = 0; i < 5; i++) await call({ token: a, json: { transcript: "x" } });
    expect((await call({ token: a, json: { transcript: "x" } })).status).toBe(429);
    expect((await rewriteAs("x")).res.status).toBe(200);
  });
});

describe("request body validation (400)", () => {
  const asUser = async (init: Parameters<typeof call>[0]) => call({ token: await mintToken(), ...init });
  const cases: Array<[string, () => Promise<Response>, string]> = [
    ["invalid JSON", () => asUser({ body: "{not json" }), "invalid request body"],
    ["an empty body", () => asUser({ body: "" }), "invalid request body"],
    ["JSON null", () => asUser({ body: "null" }), "invalid request body"],
    ["a JSON array", () => asUser({ body: '["hello"]' }), "invalid request body"],
    ["a JSON string", () => asUser({ body: '"hello"' }), "invalid request body"],
    ["a missing transcript", () => asUser({ json: {} }), "missing transcript"],
    ["an empty transcript", () => asUser({ json: { transcript: "" } }), "missing transcript"],
    ["a number transcript", () => asUser({ json: { transcript: 42 } }), "missing transcript"],
    ["an array transcript", () => asUser({ json: { transcript: ["a"] } }), "missing transcript"],
    ["an object transcript", () => asUser({ json: { transcript: { a: 1 } } }), "missing transcript"],
    ["a null transcript", () => asUser({ json: { transcript: null } }), "missing transcript"],
  ];

  for (const [name, run, error] of cases) {
    it(`rejects ${name} with 400 and makes no upstream call`, async () => {
      await expectError(await run(), 400, error);
      expect(upstream.calls).toHaveLength(0);
    });
  }

  it("does not spend the user's quota on malformed requests", async () => {
    freezeClock(); // no window boundary can fall inside this test
    const token = await mintToken({ sub: newUserId() });
    // More malformed requests than the per-minute allowance (5)...
    for (let i = 0; i < 8; i++) {
      expect((await call({ token, body: "{not json" })).status).toBe(400);
      expect((await call({ token, json: { transcript: "" } })).status).toBe(400);
    }
    // ...and the user still has their full allowance.
    for (let i = 0; i < 5; i++) {
      expect((await call({ token, json: { transcript: "hello" } })).status, `valid request ${i + 1}`).toBe(200);
    }
    expect((await call({ token, json: { transcript: "hello" } })).status).toBe(429);
  });
});

describe("size caps (413)", () => {
  it("rejects a transcript over 16,000 characters before any tier, quota or provider work", async () => {
    const { res } = await rewriteAs(text(16_001));
    await expectError(res, 413, "transcript_too_long");
    expect(upstream.calls).toHaveLength(0);
  });

  it("accepts a transcript of exactly 16,000 characters", async () => {
    const { res } = await rewriteAs(text(16_000));
    expect(res.status).toBe(200);
    expect(upstream.anthropicCalls()).toHaveLength(1);
  });

  it("rejects a 100,000-character request with 413 and no upstream call", async () => {
    const { res } = await rewriteAs(text(100_000));
    await expectError(res, 413, "transcript_too_long");
    expect(upstream.calls).toHaveLength(0);
  });

  it("does not spend quota on oversized requests", async () => {
    freezeClock(); // no window boundary can fall inside this test
    const token = await mintToken({ sub: newUserId() });
    for (let i = 0; i < 8; i++) {
      expect((await call({ token, json: { transcript: text(16_001) } })).status).toBe(413);
    }
    for (let i = 0; i < 5; i++) {
      expect((await call({ token, json: { transcript: "hello" } })).status).toBe(200);
    }
  });

  it("refuses a declared Content-Length over 64 KB without reading the body", async () => {
    let bodyWasRead = false;
    // highWaterMark 0: nothing is pulled until a consumer actually reads.
    const body = new ReadableStream<Uint8Array>(
      {
        pull(controller) {
          bodyWasRead = true;
          controller.enqueue(new TextEncoder().encode("{}"));
          controller.close();
        },
      },
      { highWaterMark: 0 }
    );
    const res = await call({
      token: await mintToken(),
      body,
      headers: { "content-type": "application/json", "content-length": String(64 * 1024 + 1) },
    });
    await expectError(res, 413, "transcript_too_long");
    expect(bodyWasRead).toBe(false);
    expect(upstream.calls).toHaveLength(0);
  });

  it("stops reading an over-64 KB body that has no Content-Length", async () => {
    let chunksPulled = 0;
    const chunk = new TextEncoder().encode(text(8 * 1024));
    const body = new ReadableStream<Uint8Array>(
      {
        pull(controller) {
          chunksPulled++;
          controller.enqueue(chunk);
          if (chunksPulled > 200) controller.close(); // ~1.6 MB if it were never cut off
        },
      },
      { highWaterMark: 0 }
    );
    const res = await call({ token: await mintToken(), body });
    await expectError(res, 413, "transcript_too_long");
    expect(chunksPulled).toBeLessThan(50);
    expect(upstream.calls).toHaveLength(0);
  });

  it("answers an oversized unauthenticated request 401, without reading it", async () => {
    const res = await call({ json: { transcript: text(100_000) } });
    await expectError(res, 401, "unauthorized");
  });
});

describe("mock LLM (dev only)", () => {
  const mockEnv = () => makeEnv({ LLM_PROVIDER: "mock" });

  it("cleans a transcript locally on a loopback hostname without calling Claude", async () => {
    const { res } = await rewriteAs("um so like send it tomorrow", { env: mockEnv() });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ rewritten: "Send it tomorrow." });
    expect(upstream.anthropicCalls()).toHaveLength(0);
  });

  it("works on 127.0.0.1 too", async () => {
    const { res } = await rewriteAs("um so like send it tomorrow", { env: mockEnv(), host: "127.0.0.1" });
    expect(await res.json()).toEqual({ rewritten: "Send it tomorrow." });
  });

  describe("fails closed to the real Claude path", () => {
    beforeEach(() => {
      upstream.anthropic = () => claudeReply("REAL-CLAUDE-PATH");
    });

    for (const host of ["proxy.example.com", "open-wispr-proxy.workers.dev", "localhost.evil.example", "127.0.0.1.nip.io", "10.0.0.5"]) {
      it(`LLM_PROVIDER=mock on non-loopback host ${host} still calls Claude`, async () => {
        const { res } = await rewriteAs("um so like send it tomorrow", { env: mockEnv(), host });
        expect(await res.json()).toEqual({ rewritten: "REAL-CLAUDE-PATH" });
        expect(upstream.anthropicCalls()).toHaveLength(1);
      });
    }

    it("LLM_PROVIDER unset on localhost calls Claude", async () => {
      const { res } = await rewriteAs("um so like send it tomorrow", { env: makeEnv(), host: "localhost" });
      expect(await res.json()).toEqual({ rewritten: "REAL-CLAUDE-PATH" });
      expect(upstream.anthropicCalls()).toHaveLength(1);
    });

    for (const value of ["", "MOCK", "true", "1", " mock"]) {
      it(`LLM_PROVIDER=${JSON.stringify(value)} on localhost calls Claude`, async () => {
        const { res } = await rewriteAs("um hi", { env: makeEnv({ LLM_PROVIDER: value }) });
        expect(await res.json()).toEqual({ rewritten: "REAL-CLAUDE-PATH" });
      });
    }
  });
});

describe("real Claude path", () => {
  it("returns the rewritten text on success and sends the expected request", async () => {
    upstream.anthropic = () => claudeReply("  Send it tomorrow.  ");
    const { res } = await rewriteAs("um so like send it tomorrow");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ rewritten: "Send it tomorrow." });

    const [sent] = upstream.anthropicCalls();
    expect(sent.url).toBe(ANTHROPIC_URL);
    expect(sent.headers.get("x-api-key")).toBe(baseEnv.ANTHROPIC_API_KEY);
    const payload = JSON.parse(sent.body);
    expect(payload.model).toBe("claude-opus-5");
    expect(payload.max_tokens).toBe(4096);
    expect(payload.messages).toEqual([{ role: "user", content: "um so like send it tomorrow" }]);
  });

  it("returns 502 when the provider answers 500", async () => {
    upstream.anthropic = () => jsonReply({ type: "error", error: { type: "api_error", message: "boom" } }, 500);
    const { res } = await rewriteAs("hello");
    await expectError(res, 502, "rewrite failed");
  });

  it("returns 502 when the provider rejects the request or the key", async () => {
    upstream.anthropic = () => jsonReply({ type: "error", error: { type: "authentication_error", message: "bad key" } }, 401);
    await expectError((await rewriteAs("hello")).res, 502, "rewrite failed");
    upstream.anthropic = () => jsonReply({ type: "error", error: { type: "invalid_request_error", message: "nope" } }, 400);
    await expectError((await rewriteAs("hello")).res, 502, "rewrite failed");
  });

  it("returns 502 when the provider connection fails", async () => {
    upstream.anthropic = () => {
      throw new TypeError("network down");
    };
    await expectError((await rewriteAs("hello")).res, 502, "rewrite failed");
  });

  it("returns 502, not truncated text, when the output hit max_tokens", async () => {
    upstream.anthropic = () => claudeReply("The meeting is at three and we should also", "max_tokens");
    const { res } = await rewriteAs("hello");
    await expectError(res, 502, "rewrite failed");
  });

  it("returns 502 when the reply has no text block", async () => {
    upstream.anthropic = () =>
      jsonReply({
        id: "msg_test",
        type: "message",
        role: "assistant",
        model: "claude-opus-5",
        content: [],
        stop_reason: "end_turn",
        stop_sequence: null,
        usage: { input_tokens: 1, output_tokens: 0 },
      });
    await expectError((await rewriteAs("hello")).res, 502, "rewrite failed");
  });
});

describe("outages (503 service_unavailable)", () => {
  async function expectOutage(res: Response) {
    await expectError(res, 503, "service_unavailable");
    expect(upstream.anthropicCalls()).toHaveLength(0);
  }

  it("Supabase answers 500", async () => {
    upstream.supabase = () => jsonReply({ message: "UPSTREAM-DETAIL-CANARY" }, 500);
    await expectOutage((await rewriteAs("hello")).res);
  });

  it("Supabase answers 503 or 401", async () => {
    upstream.supabase = () => jsonReply({ message: "x" }, 503);
    await expectOutage((await rewriteAs("hello")).res);
    upstream.supabase = () => jsonReply({ message: "x" }, 401);
    await expectOutage((await rewriteAs("hello")).res);
  });

  it("Supabase connection fails", async () => {
    upstream.supabase = () => {
      throw new TypeError("connection refused");
    };
    await expectOutage((await rewriteAs("hello")).res);
  });

  it("Supabase answers with something that is not a row list", async () => {
    upstream.supabase = () => jsonReply({ not: "an array" });
    await expectOutage((await rewriteAs("hello")).res);
    upstream.supabase = () => new Response("<html>gateway</html>", { status: 200 });
    await expectOutage((await rewriteAs("hello")).res);
  });

  it("Supabase hangs: the lookup is cut off at 3 s and answered as 503", async () => {
    upstream.supabase = hang;
    const started = Date.now();
    const { res } = await rewriteAs("hello");
    const elapsed = Date.now() - started;
    await expectOutage(res);
    expect(elapsed).toBeGreaterThanOrEqual(2500);
    expect(elapsed).toBeLessThan(6000);
  }, 10_000);

  it("the quota store fails", async () => {
    const { res } = await rewriteAs("hello", { env: brokenQuotaEnv() });
    await expectOutage(res);
  });
});

describe("misconfiguration guard", () => {
  it("the example secret in the code matches .dev.vars.example", () => {
    expect(EXAMPLE_JWT_SECRET).toBe(baseEnv.TEST_EXAMPLE_JWT_SECRET);
    expect(EXAMPLE_JWT_SECRET.startsWith("local-dev-")).toBe(true);
  });

  const exampleEnv = () => makeEnv({ SUPABASE_JWT_SECRET: EXAMPLE_JWT_SECRET, LLM_PROVIDER: "mock" });

  it("refuses to serve with the example secret on a non-loopback host, with a bare body", async () => {
    // Even a perfectly valid token (signed with the published secret) gets nothing.
    const token = await mintToken({ secret: EXAMPLE_JWT_SECRET });
    const res = await call({ token, json: { transcript: "hi" }, host: "proxy.example.com", env: exampleEnv() });
    expect(res.status).toBe(500);
    const raw = await res.text();
    expect(JSON.parse(raw)).toEqual({ error: "misconfigured" });
    expect(raw).not.toMatch(/secret|example|jwt|env/i);
    expect(upstream.calls).toHaveLength(0);
  });

  it("refuses even without a token", async () => {
    const res = await call({ json: { transcript: "hi" }, host: "proxy.example.com", env: exampleEnv() });
    await expectError(res, 500, "misconfigured");
  });

  it("still works locally with the example secret on localhost and 127.0.0.1", async () => {
    const token = await mintToken({ secret: EXAMPLE_JWT_SECRET });
    for (const host of ["localhost", "127.0.0.1"]) {
      const res = await call({ token, json: { transcript: "um hi" }, host, env: exampleEnv() });
      expect(res.status, host).toBe(200);
    }
  });

  it("does not affect a deployed Worker with a real secret", async () => {
    const { res } = await rewriteAs("um hi", { host: "proxy.example.com" });
    expect(res.status).toBe(200);
  });

  it("the test secret looks like a real one (so deployed-host tests pass the guard)", () => {
    expect(JWT_SECRET).not.toBe(EXAMPLE_JWT_SECRET);
    expect(JWT_SECRET.startsWith("local-dev-")).toBe(false);
    expect(JWT_SECRET.length).toBeGreaterThanOrEqual(32);
  });
});
