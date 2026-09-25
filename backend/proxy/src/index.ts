import type { Env, Tier } from "./types";
import { MAX_BODY_BYTES, MAX_TRANSCRIPT_CHARS } from "./types";
import { authenticate } from "./auth";
import { getUserTier } from "./tier";
import { checkAndConsumeQuota, type RateLimitResult } from "./rateLimit";
import { rewriteTranscript } from "./claude";
import { chooseProvider, mockRewrite } from "./llmProvider";
import { placeholderWebhookConfigOffLoopback, unsafeJwtSecretOffLoopback } from "./hostGuard";
import { handleStripeWebhook } from "./stripeWebhook";

export { QuotaCounter } from "./quotaCounter";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/v1/rewrite" && request.method === "POST") {
      return handleRewrite(request, env, url.hostname);
    }
    if (url.pathname === "/v1/stripe/webhook" && request.method === "POST") {
      if (placeholderWebhookConfigOffLoopback(env, url.hostname)) {
        console.error("misconfigured: refusing to serve the webhook with placeholder configuration");
        return json({ error: "misconfigured" }, 500);
      }
      return handleStripeWebhook(request, env);
    }
    return new Response("Not found", { status: 404 });
  },
};

/**
 * Per-request facts for the single log line. Deliberately closed: only a fixed
 * error kind and a hashed user id can be recorded, so no request content, token,
 * key or upstream detail has a way into the log.
 */
interface RewriteTrace {
  userHash: string | null;
  kind: string | null;
}

async function handleRewrite(request: Request, env: Env, hostname: string): Promise<Response> {
  const startedAt = Date.now();
  const trace: RewriteTrace = { userHash: null, kind: null };
  let response: Response;
  try {
    response = await rewrite(request, env, hostname, trace);
  } catch {
    // Anything unexpected: a fixed body, never a stack trace or upstream detail.
    response = reject(trace, "internal_error", 500, "internal_error");
  }
  logRewrite(response.status, Date.now() - startedAt, trace);
  return response;
}

async function rewrite(request: Request, env: Env, hostname: string, trace: RewriteTrace): Promise<Response> {
  // A deployed Worker holding a local-dev or too-short JWT secret would accept forged
  // tokens. Refuse before doing anything else, and do not say why in the body.
  if (unsafeJwtSecretOffLoopback(env, hostname)) {
    console.error("misconfigured: refusing to serve with a local-dev or too-short JWT secret");
    return reject(trace, "misconfigured", 500, "misconfigured");
  }

  const user = await authenticate(request, env);
  if (!user) return reject(trace, "unauthorized", 401, "unauthorized");
  trace.userHash = await hashUserId(user.id);

  // Validate the body before any upstream call or quota use: a malformed or
  // oversized request must not cost the user allowance or us a lookup.
  const body = await readBodyCapped(request, MAX_BODY_BYTES);
  if (body.kind === "too_large") return reject(trace, "body_too_large", 413, "transcript_too_long");
  if (body.kind === "bad_encoding") return reject(trace, "invalid_body", 400, "invalid request body");

  let parsed: unknown;
  try {
    parsed = JSON.parse(body.text);
  } catch {
    return reject(trace, "invalid_body", 400, "invalid request body");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return reject(trace, "invalid_body", 400, "invalid request body");
  }
  const transcript = (parsed as { transcript?: unknown }).transcript;
  if (typeof transcript !== "string" || transcript.trim().length === 0) {
    return reject(trace, "missing_transcript", 400, "missing transcript");
  }
  // Count Unicode code points, not UTF-16 units, so an emoji is one character.
  // The body is already capped at 64 KB, so spreading it is cheap.
  if ([...transcript].length > MAX_TRANSCRIPT_CHARS) {
    return reject(trace, "transcript_too_long", 413, "transcript_too_long");
  }

  // A failed tier or quota lookup is an outage, never "free" and never a raw 500.
  // Errors are deliberately swallowed without logging: they may carry upstream details.
  let tier: Tier;
  try {
    tier = await getUserTier(user.id, env);
  } catch {
    return reject(trace, "tier_lookup_failed", 503, "service_unavailable");
  }
  if (tier !== "pro") return reject(trace, "tier_required", 402, "rewrite requires the Pro tier");

  let quota: RateLimitResult;
  try {
    quota = await checkAndConsumeQuota(user.id, tier, env);
  } catch {
    return reject(trace, "quota_store_failed", 503, "service_unavailable");
  }
  if (!quota.allowed) return reject(trace, quota.reason, 429, quota.reason);

  try {
    const rewritten =
      chooseProvider(env, hostname) === "mock" ? mockRewrite(transcript) : await rewriteTranscript(transcript, env);
    return json({ rewritten });
  } catch {
    return reject(trace, "rewrite_failed", 502, "rewrite failed");
  }
}

type BodyResult = { kind: "ok"; text: string } | { kind: "too_large" } | { kind: "bad_encoding" };

/**
 * Reads the request body as UTF-8 text, or reports that it is larger than
 * `maxBytes` or not valid UTF-8. A declared Content-Length over the cap is
 * refused without reading anything; a missing or understated one is caught while
 * streaming, so an oversized body is never fully buffered. Exactly `maxBytes` is accepted.
 */
async function readBodyCapped(request: Request, maxBytes: number): Promise<BodyResult> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) return { kind: "too_large" };
  if (!request.body) return { kind: "ok", text: "" };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      return { kind: "too_large" };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { kind: "ok", text: new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes) };
  } catch {
    return { kind: "bad_encoding" };
  }
}

/** First 12 hex chars of SHA-256(user id): enough to correlate, never the id itself. */
async function hashUserId(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(userId));
  return Array.from(new Uint8Array(digest).slice(0, 6), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** One content-free line per rewrite request: status, latency, error kind, hashed user. */
function logRewrite(status: number, latencyMs: number, trace: RewriteTrace): void {
  try {
    console.log(
      JSON.stringify({ event: "rewrite", status, latency_ms: latencyMs, error: trace.kind, user: trace.userHash })
    );
  } catch {
    // Logging must never change the response.
  }
}

function reject(trace: RewriteTrace, kind: string, status: number, error: string): Response {
  trace.kind = kind;
  return json({ error }, status);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
