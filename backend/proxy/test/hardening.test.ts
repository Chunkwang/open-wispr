import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  ISSUER,
  SUPABASE_URL,
  baseEnv,
  call,
  claudeReply,
  freezeClock,
  installUpstream,
  jsonReply,
  makeEnv,
  mintToken,
  newUserId,
  restoreClock,
  restoreUpstream,
  rewriteAs,
  type Upstream,
} from "./helpers";
import { EXAMPLE_JWT_SECRET, isLoopbackHostname } from "../src/hostGuard";
import { tierLookupUrl } from "../src/tier";
import { supabaseBaseUrl } from "../src/supabaseUrl";

let upstream: Upstream;
beforeEach(() => {
  upstream = installUpstream();
});
afterEach(() => {
  restoreClock();
  restoreUpstream();
});

async function expectError(res: Response, status: number, error: string) {
  expect(res.status).toBe(status);
  expect(await res.json()).toEqual({ error });
}

/** A body stream that records whether anything ever read from it. */
function watchedBody(bytes: Uint8Array) {
  const state = { pulled: false };
  const body = new ReadableStream<Uint8Array>(
    {
      pull(controller) {
        state.pulled = true;
        controller.enqueue(bytes);
        controller.close();
      },
    },
    { highWaterMark: 0 }
  );
  return { body, state };
}

describe("Claude client and finish reasons", () => {
  it("makes exactly one upstream attempt on a 529 (no SDK retries), then 502", async () => {
    upstream.anthropic = () => jsonReply({ type: "error", error: { type: "overloaded_error", message: "busy" } }, 529);
    const { res } = await rewriteAs("hello");
    await expectError(res, 502, "rewrite failed");
    expect(upstream.anthropicCalls()).toHaveLength(1);
  });

  it("makes exactly one attempt on a 500 and on a dropped connection", async () => {
    upstream.anthropic = () => jsonReply({ type: "error", error: { type: "api_error", message: "x" } }, 500);
    await rewriteAs("hello");
    expect(upstream.anthropicCalls()).toHaveLength(1);
    upstream.calls.length = 0;
    upstream.anthropic = () => {
      throw new TypeError("network down");
    };
    await rewriteAs("hello");
    expect(upstream.anthropicCalls()).toHaveLength(1);
  });

  for (const reason of ["end_turn", "stop_sequence"]) {
    it(`accepts stop_reason ${reason}`, async () => {
      upstream.anthropic = () => claudeReply("Done.", reason);
      const { res } = await rewriteAs("hello");
      expect(await res.json()).toEqual({ rewritten: "Done." });
    });
  }

  for (const reason of ["max_tokens", "refusal", "pause_turn", "tool_use", "something_new", ""]) {
    it(`rejects stop_reason ${JSON.stringify(reason)} with 502`, async () => {
      upstream.anthropic = () => claudeReply("Some text that must not be inserted.", reason);
      const { res } = await rewriteAs("hello");
      await expectError(res, 502, "rewrite failed");
    });
  }

  it("rejects a null stop_reason with 502", async () => {
    upstream.anthropic = () =>
      jsonReply({
        id: "m",
        type: "message",
        role: "assistant",
        model: "claude-opus-5",
        content: [{ type: "text", text: "text" }],
        stop_reason: null,
        stop_sequence: null,
        usage: { input_tokens: 1, output_tokens: 1 },
      });
    await expectError((await rewriteAs("hello")).res, 502, "rewrite failed");
  });

  for (const text of ["", "   ", "\n\t "]) {
    it(`rejects empty or whitespace-only output ${JSON.stringify(text)} with 502`, async () => {
      upstream.anthropic = () => claudeReply(text);
      await expectError((await rewriteAs("hello")).res, 502, "rewrite failed");
    });
  }
});

describe("misconfiguration guard (deployed host)", () => {
  const deployed = "proxy.example.com";

  for (const [name, secret] of [
    ["the published example secret", EXAMPLE_JWT_SECRET],
    ["another local-dev- secret", "local-dev-some-other-long-secret-value-0123456789"],
    ["a short secret", "short-secret"],
    ["a 31-character secret", "a".repeat(31)],
    ["an empty secret", ""],
  ] as const) {
    it(`refuses ${name} off loopback with a fixed body`, async () => {
      const res = await call({
        token: await mintToken({ secret: secret || "x" }),
        json: { transcript: "hi" },
        host: deployed,
        env: makeEnv({ SUPABASE_JWT_SECRET: secret }),
      });
      expect(res.status).toBe(500);
      expect(await res.text()).toBe('{"error":"misconfigured"}');
      expect(upstream.calls).toHaveLength(0);
    });
  }

  it("accepts a 32-character secret that is not a local-dev value", async () => {
    const secret = "k".repeat(32);
    const { res } = await rewriteAs("hi", {
      host: deployed,
      token: await mintToken({ secret }),
      env: makeEnv({ SUPABASE_JWT_SECRET: secret }),
    });
    expect(res.status).toBe(200);
  });

  it("allows short and local-dev secrets on loopback (local development)", async () => {
    for (const secret of ["local-dev-x", "short"]) {
      const { res } = await rewriteAs("hi", {
        token: await mintToken({ secret }),
        env: makeEnv({ SUPABASE_JWT_SECRET: secret }),
      });
      expect(res.status, secret).toBe(200);
    }
  });

  describe("webhook route", () => {
    const webhook = (env: ReturnType<typeof makeEnv>, host = deployed) =>
      call({ path: "/v1/stripe/webhook", host, body: "{}", env });

    for (const [name, override] of [
      ["STRIPE_WEBHOOK_SECRET", { STRIPE_WEBHOOK_SECRET: "whsec_placeholder" }],
      ["STRIPE_SECRET_KEY", { STRIPE_SECRET_KEY: "sk_test_placeholder" }],
      ["SUPABASE_SERVICE_ROLE_KEY", { SUPABASE_SERVICE_ROLE_KEY: "local-dev-service-role-key" }],
    ] as const) {
      it(`refuses the placeholder ${name} off loopback`, async () => {
        const res = await webhook(makeEnv(override));
        expect(res.status).toBe(500);
        expect(await res.text()).toBe('{"error":"misconfigured"}');
      });

      it(`lets the placeholder ${name} through on loopback (goes on to the signature check)`, async () => {
        const res = await webhook(makeEnv(override), "localhost");
        expect(res.status).toBe(400);
        expect(await res.text()).toBe("missing signature");
      });
    }

    it("serves normally off loopback with real-looking values", async () => {
      const res = await webhook(makeEnv());
      expect(res.status).toBe(400);
      expect(await res.text()).toBe("missing signature");
    });
  });

  it("the example constant equals .dev.vars.example", () => {
    expect(EXAMPLE_JWT_SECRET).toBe(baseEnv.TEST_EXAMPLE_JWT_SECRET);
  });
});

describe("loopback host set is pinned", () => {
  const loopback = ["127.0.0.1", "localhost"];
  const notLoopback = ["0.0.0.0", "127.0.0.2", "[::1]", "::1", "localhost.", "LOCALHOST", "127.0.0.1.nip.io", "localhost.evil.example", ""];

  it("only 127.0.0.1 and localhost are loopback", () => {
    for (const h of loopback) expect(isLoopbackHostname(h), h).toBe(true);
    for (const h of notLoopback) expect(isLoopbackHostname(h), JSON.stringify(h)).toBe(false);
  });

  for (const host of ["0.0.0.0", "127.0.0.2", "[::1]", "localhost."]) {
    it(`the mock LLM is not used on ${host} (through the handler)`, async () => {
      upstream.anthropic = () => claudeReply("REAL-CLAUDE-PATH");
      const { res } = await rewriteAs("um hi", { host, env: makeEnv({ LLM_PROVIDER: "mock" }) });
      expect(await res.json()).toEqual({ rewritten: "REAL-CLAUDE-PATH" });
    });

    it(`the deployed-host guard applies on ${host}`, async () => {
      const res = await call({
        host,
        json: { transcript: "hi" },
        env: makeEnv({ SUPABASE_JWT_SECRET: EXAMPLE_JWT_SECRET }),
      });
      await expectError(res, 500, "misconfigured");
    });
  }
});

describe("token claims", () => {
  const body = { transcript: "hello" };
  it("rejects a token with no exp claim", async () => {
    const res = await call({ token: await mintToken({ expiresIn: null }), json: body });
    await expectError(res, 401, "unauthorized");
    expect(upstream.calls).toHaveLength(0);
  });

  for (const sub of ["not-a-uuid", "", "admin", "1 or 1=1", `${crypto.randomUUID()}x`, `../${crypto.randomUUID()}`, "12345678-1234-1234-1234-12345678901"]) {
    it(`rejects sub ${JSON.stringify(sub)} that is not a UUID`, async () => {
      const res = await call({ token: await mintToken({ sub }), json: body });
      await expectError(res, 401, "unauthorized");
      expect(upstream.calls).toHaveLength(0);
    });
  }

  it("accepts an upper-case UUID sub", async () => {
    const { res } = await rewriteAs("hello", { userId: newUserId().toUpperCase() });
    expect(res.status).toBe(200);
  });

  it("accepts aud as a list that includes authenticated", async () => {
    const res = await call({ token: await mintToken({ aud: ["other", "authenticated"] }), json: body });
    expect(res.status).toBe(200);
  });
});

describe("SUPABASE_URL normalisation", () => {
  it("strips trailing slashes", () => {
    expect(supabaseBaseUrl("https://x.supabase.co///")).toBe("https://x.supabase.co");
    expect(supabaseBaseUrl("https://x.supabase.co")).toBe("https://x.supabase.co");
    expect(supabaseBaseUrl(undefined)).toBe("");
  });

  it("the tier lookup URL has no double slash and matches exactly what the upstream sees", async () => {
    const userId = newUserId();
    const { res } = await rewriteAs("hello", { userId, env: makeEnv({ SUPABASE_URL: `${SUPABASE_URL}//` }) });
    expect(res.status).toBe(200);
    const [lookup] = upstream.supabaseCalls();
    expect(lookup.url).toBe(`${SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}&select=tier`);
    expect(lookup.method).toBe("GET");
  });

  it("a token issued for the slash-terminated URL form is still checked against the normalised issuer", async () => {
    const { res } = await rewriteAs("hello", {
      token: await mintToken({ iss: ISSUER }),
      env: makeEnv({ SUPABASE_URL: `${SUPABASE_URL}/` }),
    });
    expect(res.status).toBe(200);
  });
});

describe("tier lookup request", () => {
  it("sends the service-role key as both apikey and Authorization: Bearer", async () => {
    await rewriteAs("hello");
    const [lookup] = upstream.supabaseCalls();
    expect(lookup.headers.get("apikey")).toBe(baseEnv.SUPABASE_SERVICE_ROLE_KEY);
    expect(lookup.headers.get("authorization")).toBe(`Bearer ${baseEnv.SUPABASE_SERVICE_ROLE_KEY}`);
  });

  it("URL-encodes a hostile user id so it cannot add or change query parameters", () => {
    const url = tierLookupUrl("abc&select=*&id=eq.other#frag ?x", { SUPABASE_URL });
    expect(url).toBe(`${SUPABASE_URL}/rest/v1/profiles?id=eq.abc%26select%3D*%26id%3Deq.other%23frag%20%3Fx&select=tier`);
    const parsed = new URL(url);
    expect([...parsed.searchParams.keys()]).toEqual(["id", "select"]);
    expect(parsed.searchParams.get("select")).toBe("tier");
    expect(parsed.hash).toBe("");
  });
});

describe("transcript validation details", () => {
  it("rejects a whitespace-only transcript with 400 and spends no quota", async () => {
    freezeClock();
    const token = await mintToken({ sub: newUserId() });
    for (const ws of [" ", "   ", "\n", "\t \r\n", " ", " "]) {
      await expectError(await call({ token, json: { transcript: ws } }), 400, "missing transcript");
    }
    expect(upstream.calls).toHaveLength(0);
    for (let i = 0; i < 5; i++) {
      expect((await call({ token, json: { transcript: "hello" } })).status).toBe(200);
    }
  });

  it("rejects a body that is not valid UTF-8 with 400 invalid request body, before any upstream call", async () => {
    const prefix = new TextEncoder().encode('{"transcript":"caf');
    const bytes = new Uint8Array([...prefix, 0xc3, 0x28, 0xff, 0xfe, ...new TextEncoder().encode('"}')]);
    const res = await call({ token: await mintToken(), body: bytes });
    await expectError(res, 400, "invalid request body");
    expect(upstream.calls).toHaveLength(0);
  });

  it("accepts valid multibyte UTF-8", async () => {
    const { res } = await rewriteAs("café 日本語 😀", { env: makeEnv({ LLM_PROVIDER: "mock" }) });
    expect(res.status).toBe(200);
  });
});

describe("caps count Unicode code points, and the 64 KB body cap also applies", () => {
  const emoji = (n: number) => "😀".repeat(n); // 1 code point, 2 UTF-16 units, 4 UTF-8 bytes
  const cjk = (n: number) => "漢".repeat(n); // 1 code point, 3 bytes

  it("accepts 16,000 emoji (about 64,017 bytes, under the 64 KB body cap)", async () => {
    const json = JSON.stringify({ transcript: emoji(16_000) });
    expect(new TextEncoder().encode(json).length).toBeLessThan(64 * 1024);
    const { res } = await rewriteAs(emoji(16_000));
    expect(res.status).toBe(200);
  });

  it("accepts 8,001 emoji (more than 16,000 UTF-16 units)", async () => {
    const { res } = await rewriteAs(emoji(8_001));
    expect(res.status).toBe(200);
  });

  it("rejects 16,001 emoji with 413 before any upstream call", async () => {
    const { res } = await rewriteAs(emoji(16_001));
    await expectError(res, 413, "transcript_too_long");
    expect(upstream.calls).toHaveLength(0);
  });

  it("accepts 16,000 CJK characters and rejects 16,001", async () => {
    expect((await rewriteAs(cjk(16_000))).res.status).toBe(200);
    upstream.calls.length = 0;
    const { res } = await rewriteAs(cjk(16_001));
    await expectError(res, 413, "transcript_too_long");
    expect(upstream.calls).toHaveLength(0);
  });

  it("counts a combining sequence per code point (16,001 code points is over)", async () => {
    const { res } = await rewriteAs("é".repeat(8_001)); // 16,002 code points
    await expectError(res, 413, "transcript_too_long");
  });
});

describe("64 KB body cap boundary (65,536 bytes is accepted, 65,537 is not)", () => {
  /** Valid JSON of exactly `bytes` bytes: a short transcript plus ignored padding. */
  function bodyOfSize(bytes: number): Uint8Array {
    const head = '{"transcript":"hi","pad":"';
    const tail = '"}';
    const pad = "x".repeat(bytes - head.length - tail.length);
    const out = new TextEncoder().encode(head + pad + tail);
    expect(out.length).toBe(bytes);
    return out;
  }

  function streamOf(bytes: Uint8Array): ReadableStream<Uint8Array> {
    let offset = 0;
    return new ReadableStream<Uint8Array>(
      {
        pull(controller) {
          if (offset >= bytes.length) return controller.close();
          controller.enqueue(bytes.slice(offset, offset + 4096));
          offset += 4096;
        },
      },
      { highWaterMark: 0 }
    );
  }

  it("with a Content-Length: 65,536 accepted, 65,537 rejected", async () => {
    const token = await mintToken();
    expect((await call({ token, body: bodyOfSize(65_536) })).status).toBe(200);
    await expectError(await call({ token, body: bodyOfSize(65_537) }), 413, "transcript_too_long");
  });

  it("with no Content-Length (streamed): 65,536 accepted, 65,537 rejected", async () => {
    const token = await mintToken();
    expect((await call({ token, body: streamOf(bodyOfSize(65_536)) })).status).toBe(200);
    await expectError(await call({ token, body: streamOf(bodyOfSize(65_537)) }), 413, "transcript_too_long");
  });
});

describe("unauthenticated requests", () => {
  it("are answered 401 without the request body being read", async () => {
    const { body, state } = watchedBody(new TextEncoder().encode('{"transcript":"hello"}'));
    const res = await call({ body });
    await expectError(res, 401, "unauthorized");
    expect(state.pulled).toBe(false);
    expect(upstream.calls).toHaveLength(0);
  });

  it("are refused as misconfigured without the request body being read", async () => {
    const { body, state } = watchedBody(new TextEncoder().encode("{}"));
    const res = await call({ body, host: "proxy.example.com", env: makeEnv({ SUPABASE_JWT_SECRET: EXAMPLE_JWT_SECRET }) });
    await expectError(res, 500, "misconfigured");
    expect(state.pulled).toBe(false);
  });

  it("control: an authenticated request does read the body", async () => {
    const { body, state } = watchedBody(new TextEncoder().encode('{"transcript":"hello"}'));
    const res = await call({ token: await mintToken(), body });
    expect(res.status).toBe(200);
    expect(state.pulled).toBe(true);
  });
});
