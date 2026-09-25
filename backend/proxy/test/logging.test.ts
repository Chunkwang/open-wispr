import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
import {
  baseEnv,
  brokenQuotaEnv,
  call,
  claudeReply,
  hang,
  installUpstream,
  jsonReply,
  makeEnv,
  mintToken,
  newUserId,
  restoreUpstream,
  tierReply,
  type Upstream,
} from "./helpers";
import { EXAMPLE_JWT_SECRET } from "../src/hostGuard";

// Unique strings that must never reach a log line.
const TRANSCRIPT = "CANARY-TRANSCRIPT-8842 please wire the money to account 12345";
const CLAUDE_OUTPUT = "CANARY-REWRITE-5521 Please wire the money.";
const UPSTREAM_BODY = "CANARY-UPSTREAM-BODY-9137";
const THROWN = "CANARY-THROWN-MESSAGE-4410";

const METHODS = ["log", "info", "warn", "error", "debug"] as const;

let upstream: Upstream;
let spies: Array<MockInstance>;
let lines: string[];

const render = (arg: unknown): string => {
  if (typeof arg === "string") return arg;
  if (arg instanceof Error) return `${arg.name}: ${arg.message}\n${arg.stack ?? ""}`;
  try {
    return JSON.stringify(arg);
  } catch {
    return String(arg);
  }
};

beforeEach(() => {
  upstream = installUpstream();
  lines = [];
  spies = METHODS.map((m) => vi.spyOn(console, m).mockImplementation((...args: unknown[]) => void lines.push(args.map(render).join(" "))));
});
afterEach(() => {
  spies.forEach((s) => s.mockRestore());
  restoreUpstream();
});

async function sha12(id: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id));
  return Array.from(new Uint8Array(d).slice(0, 6), (b) => b.toString(16).padStart(2, "0")).join("");
}

interface Scenario {
  name: string;
  status: number;
  kind: string | null;
  /** True when the request is authenticated far enough to have a user. */
  hasUser: boolean;
  run: (ctx: { userId: string; token: string }) => Promise<Response>;
  setup?: () => void;
  host?: string;
}

const post = (extra: Partial<Parameters<typeof call>[0]>, ctx: { token: string }, transcript: unknown = TRANSCRIPT) =>
  call({ token: ctx.token, json: { transcript }, ...extra });

const scenarios: Scenario[] = [
  {
    name: "success (mock LLM)",
    status: 200,
    kind: null,
    hasUser: true,
    run: (c) => post({ env: makeEnv({ LLM_PROVIDER: "mock" }) }, c),
  },
  {
    name: "success (Claude path)",
    status: 200,
    kind: null,
    hasUser: true,
    setup: () => (upstream.anthropic = () => claudeReply(CLAUDE_OUTPUT)),
    run: (c) => post({}, c),
  },
  { name: "401 no auth header", status: 401, kind: "unauthorized", hasUser: false, run: () => call({ json: { transcript: TRANSCRIPT } }) },
  {
    name: "401 tampered token",
    status: 401,
    kind: "unauthorized",
    hasUser: false,
    run: (c) => call({ token: c.token.slice(0, -4) + "AAAA", json: { transcript: TRANSCRIPT } }),
  },
  {
    name: "400 invalid JSON",
    status: 400,
    kind: "invalid_body",
    hasUser: true,
    run: (c) => call({ token: c.token, body: `{"transcript": "${TRANSCRIPT}` }),
  },
  { name: "400 missing transcript", status: 400, kind: "missing_transcript", hasUser: true, run: (c) => post({}, c, 42) },
  {
    name: "413 transcript too long",
    status: 413,
    kind: "transcript_too_long",
    hasUser: true,
    run: (c) => post({}, c, TRANSCRIPT + "a".repeat(16_000)),
  },
  {
    name: "413 body too large",
    status: 413,
    kind: "body_too_large",
    hasUser: true,
    run: (c) => post({}, c, TRANSCRIPT + "a".repeat(100_000)),
  },
  {
    name: "402 free tier",
    status: 402,
    kind: "tier_required",
    hasUser: true,
    setup: () => (upstream.supabase = () => tierReply("free")),
    run: (c) => post({}, c),
  },
  {
    name: "503 Supabase 500 with a body",
    status: 503,
    kind: "tier_lookup_failed",
    hasUser: true,
    setup: () => (upstream.supabase = () => jsonReply({ message: UPSTREAM_BODY }, 500)),
    run: (c) => post({}, c),
  },
  {
    name: "503 Supabase connection error carrying detail",
    status: 503,
    kind: "tier_lookup_failed",
    hasUser: true,
    setup: () =>
      (upstream.supabase = () => {
        throw new TypeError(`${UPSTREAM_BODY} ${TRANSCRIPT}`);
      }),
    run: (c) => post({}, c),
  },
  {
    name: "503 Supabase hangs",
    status: 503,
    kind: "tier_lookup_failed",
    hasUser: true,
    setup: () => (upstream.supabase = hang),
    run: (c) => post({}, c),
  },
  {
    name: "503 quota store down",
    status: 503,
    kind: "quota_store_failed",
    hasUser: true,
    run: (c) => post({ env: brokenQuotaEnv() }, c),
  },
  {
    name: "502 provider 500 with a body",
    status: 502,
    kind: "rewrite_failed",
    hasUser: true,
    setup: () =>
      (upstream.anthropic = () =>
        jsonReply({ type: "error", error: { type: "api_error", message: `${UPSTREAM_BODY} ${TRANSCRIPT}` } }, 500)),
    run: (c) => post({}, c),
  },
  {
    name: "502 provider truncated output (max_tokens)",
    status: 502,
    kind: "rewrite_failed",
    hasUser: true,
    setup: () => (upstream.anthropic = () => claudeReply(CLAUDE_OUTPUT, "max_tokens")),
    run: (c) => post({}, c),
  },
  {
    name: "500 misconfigured (example secret off loopback)",
    status: 500,
    kind: "misconfigured",
    hasUser: false,
    host: "proxy.example.com",
    run: async (c) =>
      call({
        host: "proxy.example.com",
        token: await mintToken({ secret: EXAMPLE_JWT_SECRET }),
        json: { transcript: TRANSCRIPT },
        env: makeEnv({ SUPABASE_JWT_SECRET: EXAMPLE_JWT_SECRET }),
      }),
  },
  {
    name: "500 unexpected exception whose message carries content",
    status: 500,
    kind: "internal_error",
    hasUser: false,
    run: (c) => {
      const env = makeEnv();
      Object.defineProperty(env, "SUPABASE_URL", {
        get() {
          throw new Error(`${THROWN} ${TRANSCRIPT} ${c.token}`);
        },
      });
      return post({ env }, c);
    },
  },
];

describe("content-free logging", () => {
  it("positive control: the spies see the Worker's own log line", async () => {
    const userId = newUserId();
    await call({ token: await mintToken({ sub: userId }), json: { transcript: "hello" } });
    expect(lines.some((l) => l.includes('"event":"rewrite"'))).toBe(true);
  });

  for (const s of scenarios) {
    it(`logs one content-free line for: ${s.name}`, async () => {
      s.setup?.();
      const userId = newUserId();
      const token = await mintToken({ sub: userId });
      const res = await s.run({ userId, token });
      expect(res.status).toBe(s.status);
      const responseText = await res.text();

      // Exactly one structured rewrite line, with only the allowed fields.
      const rewriteLines = lines.filter((l) => l.includes('"event":"rewrite"'));
      expect(rewriteLines).toHaveLength(1);
      const entry = JSON.parse(rewriteLines[0]);
      expect(Object.keys(entry).sort()).toEqual(["error", "event", "latency_ms", "status", "user"]);
      expect(entry.status).toBe(s.status);
      expect(entry.error).toBe(s.kind);
      expect(typeof entry.latency_ms).toBe("number");
      expect(entry.latency_ms).toBeGreaterThanOrEqual(0);
      if (s.hasUser) expect(entry.user).toBe(await sha12(userId));
      else expect(entry.user).toBeNull();
      expect(entry.user === null || /^[0-9a-f]{12}$/.test(entry.user)).toBe(true);

      // Nothing sensitive anywhere in any console channel.
      const everything = lines.join("\n");
      const forbidden: Record<string, string> = {
        "transcript text": "CANARY-TRANSCRIPT",
        "rewritten text": "CANARY-REWRITE",
        "upstream body": UPSTREAM_BODY,
        "thrown error message": THROWN,
        "bearer token": token,
        "JWT header prefix": "eyJ",
        "Bearer scheme": "Bearer ",
        "JWT secret": baseEnv.SUPABASE_JWT_SECRET,
        "example secret": EXAMPLE_JWT_SECRET,
        "service-role key": baseEnv.SUPABASE_SERVICE_ROLE_KEY,
        "Anthropic key": baseEnv.ANTHROPIC_API_KEY,
        "raw user id": userId,
      };
      for (const [what, needle] of Object.entries(forbidden)) {
        expect(everything.includes(needle), `${s.name}: log leaked the ${what}`).toBe(false);
      }

      // Error bodies are fixed strings too: no echo of content or upstream detail.
      if (s.status !== 200) {
        expect(responseText).not.toContain("CANARY");
        expect(responseText).not.toContain(token);
      }
    });
  }

  it("the misconfiguration message is a fixed line without the secret", async () => {
    await call({
      host: "proxy.example.com",
      json: { transcript: "x" },
      env: makeEnv({ SUPABASE_JWT_SECRET: EXAMPLE_JWT_SECRET }),
    });
    const errors = lines.filter((l) => l.startsWith("misconfigured"));
    expect(errors).toHaveLength(1);
    expect(errors[0]).not.toContain(EXAMPLE_JWT_SECRET);
  });

  it("never logs the Stripe or Supabase secrets on the rewrite path either", async () => {
    const token = await mintToken({ sub: newUserId() });
    await call({ token, json: { transcript: TRANSCRIPT } });
    const everything = lines.join("\n");
    for (const secret of [baseEnv.STRIPE_SECRET_KEY, baseEnv.STRIPE_WEBHOOK_SECRET, baseEnv.SUPABASE_SERVICE_ROLE_KEY]) {
      expect(everything.includes(secret)).toBe(false);
    }
  });
});
