import { env as rawEnv, exports } from "cloudflare:workers";
import { SignJWT } from "jose";
import { vi, type MockInstance } from "vitest";
import worker from "../src/index";
import type { Env } from "../src/types";

/**
 * Test plumbing. Every request goes through the Worker's `fetch` handler with an
 * explicit env, so the tests exercise the same entry point as production and do
 * not depend on any developer's .dev.vars (which may set LLM_PROVIDER=mock).
 * Quota is a real Durable Object (QuotaCounter) behind the Worker; tests go through
 * the handler and only `brokenQuotaEnv` / `hangingQuotaEnv` name the binding.
 */

// The test bindings always carry a JWT secret (Env makes it optional because jwks mode needs none).
export type TestEnv = Env & { SUPABASE_JWT_SECRET: string; TEST_EXAMPLE_JWT_SECRET: string };
export const baseEnv = rawEnv as unknown as TestEnv;

export const SUPABASE_URL = baseEnv.SUPABASE_URL;
export const JWT_SECRET = baseEnv.SUPABASE_JWT_SECRET;
export const ISSUER = `${SUPABASE_URL}/auth/v1`;
export const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

/** The env every test starts from: real bindings, mock LLM off. */
export function makeEnv(overrides: Partial<Env> = {}): Env {
  return { ...baseEnv, LLM_PROVIDER: undefined, ...overrides } as Env;
}

/** The real entrypoint, for the few tests that do not need to vary env. */
export const entrypoint = (exports as unknown as { default: unknown }).default as { fetch(request: Request): Promise<Response> };

export function newUserId(): string {
  return crypto.randomUUID();
}

export interface TokenOptions {
  sub?: string | null;
  secret?: string;
  /** Sign with this key instead of the HMAC secret (e.g. an ES256 or RS256 private key). */
  key?: Parameters<SignJWT["sign"]>[0];
  alg?: string;
  /** Adds a `kid` header. */
  kid?: string;
  /** Extra protected-header fields (e.g. `jku`), applied last. */
  header?: Record<string, unknown>;
  iss?: string | null;
  aud?: string | string[] | null;
  /** Seconds from now; negative means already expired; null means no `exp` claim at all. */
  expiresIn?: number | null;
}

export async function mintToken(opts: TokenOptions = {}): Promise<string> {
  const jwt = new SignJWT({ role: "authenticated" }).setProtectedHeader({
    alg: opts.alg ?? "HS256",
    typ: "JWT",
    ...(opts.kid ? { kid: opts.kid } : {}),
    ...opts.header,
  });
  if (opts.sub !== null) jwt.setSubject(opts.sub ?? newUserId());
  if (opts.iss !== null) jwt.setIssuer(opts.iss ?? ISSUER);
  if (opts.aud !== null) jwt.setAudience(opts.aud ?? "authenticated");
  const now = Math.floor(Date.now() / 1000);
  jwt.setIssuedAt(now - 10);
  if (opts.expiresIn !== null) jwt.setExpirationTime(now + (opts.expiresIn ?? 3600));
  return jwt.sign(opts.key ?? new TextEncoder().encode(opts.secret ?? JWT_SECRET));
}

export interface CallOptions {
  path?: string;
  method?: string;
  host?: string;
  token?: string | null;
  authorization?: string;
  headers?: Record<string, string>;
  body?: BodyInit | null;
  /** Convenience: JSON-encodes this as the body. */
  json?: unknown;
  env?: Env;
}

/** Calls the Worker's fetch handler with a request, defaulting to POST /v1/rewrite on localhost. */
export async function call(opts: CallOptions = {}): Promise<Response> {
  const headers = new Headers(opts.headers);
  if (opts.authorization !== undefined) headers.set("authorization", opts.authorization);
  else if (opts.token) headers.set("authorization", `Bearer ${opts.token}`);
  let body: BodyInit | null | undefined = opts.body;
  if (opts.json !== undefined) {
    body = JSON.stringify(opts.json);
    headers.set("content-type", "application/json");
  }
  const init: RequestInit & { duplex?: "half" } = { method: opts.method ?? "POST", headers, body };
  if (body instanceof ReadableStream) init.duplex = "half";
  const request = new Request(`http://${opts.host ?? "localhost"}${opts.path ?? "/v1/rewrite"}`, init);
  return worker.fetch(request, opts.env ?? makeEnv());
}

/** Signs in a fresh user and posts a transcript. Returns the response and the user id. */
export async function rewriteAs(
  transcript: unknown,
  opts: { userId?: string; token?: string } & Omit<CallOptions, "token" | "json"> = {}
): Promise<{ res: Response; userId: string; token: string }> {
  const userId = opts.userId ?? newUserId();
  const token = opts.token ?? (await mintToken({ sub: userId }));
  const res = await call({ ...opts, token, json: { transcript } });
  return { res, userId, token };
}

/** Signs in a fresh user and posts a voice edit to /v1/edit. Extra body fields go in `extra`. */
export async function editAs(
  instruction: unknown,
  selection: unknown,
  opts: { userId?: string; token?: string; extra?: Record<string, unknown> } & Omit<CallOptions, "token" | "json" | "path"> = {}
): Promise<{ res: Response; userId: string; token: string }> {
  const userId = opts.userId ?? newUserId();
  const token = opts.token ?? (await mintToken({ sub: userId }));
  const { extra, userId: _u, token: _t, ...rest } = opts;
  const res = await call({ ...rest, token, path: "/v1/edit", json: { instruction, selection, ...extra } });
  return { res, userId, token };
}

// ---------------------------------------------------------------------------
// Outbound fetch mock. workerd tests share one isolate with the Worker, so
// replacing globalThis.fetch intercepts the Worker's Supabase and Anthropic
// calls. Anything not explicitly routed throws: no test can reach the network.
// ---------------------------------------------------------------------------

export type Handler = (request: Request) => Response | Promise<Response>;

export interface OutboundCall {
  url: string;
  method: string;
  headers: Headers;
  body: string;
}

export interface Upstream {
  supabase: Handler;
  anthropic: Handler;
  calls: OutboundCall[];
  supabaseCalls(): OutboundCall[];
  anthropicCalls(): OutboundCall[];
}

let fetchSpy: MockInstance<typeof fetch> | undefined;

export function installUpstream(): Upstream {
  const upstream: Upstream = {
    supabase: () => tierReply("pro"),
    anthropic: () => claudeReply("Rewritten."),
    calls: [],
    supabaseCalls: () => upstream.calls.filter((c) => c.url.startsWith(SUPABASE_URL)),
    anthropicCalls: () => upstream.calls.filter((c) => c.url.startsWith("https://api.anthropic.com")),
  };
  fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input as RequestInfo, init);
    upstream.calls.push({
      url: request.url,
      method: request.method,
      headers: request.headers,
      body: await request.clone().text(),
    });
    // Route the original request so abort signals reach the handler.
    if (request.url.startsWith(`${SUPABASE_URL}/`)) return runHandler(upstream.supabase, request, init?.signal ?? request.signal);
    if (request.url.startsWith("https://api.anthropic.com/")) return runHandler(upstream.anthropic, request, init?.signal ?? request.signal);
    throw new TypeError(`unexpected outbound fetch in test: ${new URL(request.url).origin}`);
  });
  return upstream;
}

export function restoreUpstream(): void {
  fetchSpy?.mockRestore();
  fetchSpy = undefined;
}

function runHandler(handler: Handler, request: Request, signal: AbortSignal | null | undefined): Promise<Response> {
  const abort = new Promise<never>((_, reject) => {
    const fail = () => reject(new DOMException("The operation was aborted", "AbortError"));
    if (signal?.aborted) fail();
    else signal?.addEventListener("abort", fail, { once: true });
  });
  return Promise.race([Promise.resolve().then(() => handler(request)), abort]);
}

export function jsonReply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export function tierReply(tier: string | null): Response {
  return jsonReply(tier === null ? [] : [{ tier }]);
}

/** A well-formed Anthropic Messages API reply. */
export function claudeReply(text: string, stopReason: string = "end_turn"): Response {
  return jsonReply({
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-opus-5",
    content: [{ type: "text", text }],
    stop_reason: stopReason,
    stop_sequence: null,
    usage: { input_tokens: 10, output_tokens: 10 },
  });
}

/** Never answers; only an abort signal ends it (like a hung upstream). */
export const hang: Handler = () => new Promise<Response>(() => {});

export const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Freezes only `Date` (timers stay real) at the middle of a UTC minute, so a test
 * that makes several requests cannot straddle a quota-window boundary. The Worker
 * shares the isolate, so its `Date.now()` is frozen too. Returns helpers to move time.
 * Call `restoreClock()` in afterEach.
 */
export function freezeClock(): { now(): number; advance(ms: number): void } {
  const t = Date.now();
  const midMinute = t - (t % 60_000) + 30_000;
  vi.useFakeTimers({ toFake: ["Date"], now: midMinute });
  return {
    now: () => Date.now(),
    advance: (ms: number) => vi.setSystemTime(Date.now() + ms),
  };
}

export function restoreClock(): void {
  vi.useRealTimers();
}

/** An env whose quota Durable Object always fails. The ONE place tests break the quota binding by name. */
export function brokenQuotaEnv(): Env {
  const down = () => {
    throw new Error("quota store down");
  };
  const namespace = {
    idFromName: (name: string) => ({ name }),
    get: () => ({ consume: down }),
  } as unknown as Env["QUOTA"];
  return makeEnv({ QUOTA: namespace });
}

/** An env whose quota Durable Object never answers (a hung store). */
export function hangingQuotaEnv(): Env {
  const namespace = {
    idFromName: (name: string) => ({ name }),
    get: () => ({ consume: () => new Promise(() => {}) }),
  } as unknown as Env["QUOTA"];
  return makeEnv({ QUOTA: namespace });
}
