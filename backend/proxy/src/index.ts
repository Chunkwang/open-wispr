import type { Env, Tier } from "./types";
import {
  MAX_BODY_BYTES,
  MAX_ASK_BODY_BYTES,
  MAX_ASK_INSTRUCTION_CHARS,
  MAX_ASK_TEXT_CHARS,
  MAX_ASK_UI_TREE_CHARS,
  MAX_EDIT_CONTEXT_APP_CHARS,
  MAX_EDIT_CONTEXT_WINDOW_TITLE_CHARS,
  MAX_EDIT_INSTRUCTION_CHARS,
  MAX_EDIT_SELECTION_CHARS,
  MAX_TRANSCRIPT_CHARS,
  type QuotaKind,
} from "./types";
import { AuthUnavailableError, MisconfiguredError, authenticate, type AuthedUser } from "./auth";
import { getUserTier } from "./tier";
import { checkAndConsumeQuota, type RateLimitResult } from "./rateLimit";
import { askQuestion, editSelection, rewriteTranscript } from "./claude";
import { preserveEdgeWhitespace, type EditContext } from "./editPrompt";
import { chooseProvider, mockAsk, mockEdit, mockRewrite } from "./llmProvider";
import { placeholderStripeConfigOffLoopback } from "./hostGuard";
import { readBodyCapped } from "./httpBody";
import { handleEvents } from "./events";
import { handleReferralRedeem } from "./referral";
import { handleStripeWebhook } from "./stripeWebhook";
import { handleBillingCheckout, handleBillingPortal } from "./billing";
import { handleMe } from "./me";

export { QuotaCounter } from "./quotaCounter";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/v1/rewrite" && request.method === "POST") {
      return handleProtected(request, env, url.hostname, rewriteEndpoint);
    }
    if (url.pathname === "/v1/edit" && request.method === "POST") {
      return handleProtected(request, env, url.hostname, editEndpoint);
    }
    if (url.pathname === "/v1/ask" && request.method === "POST") {
      return handleProtected(request, env, url.hostname, askEndpoint, MAX_ASK_BODY_BYTES);
    }
    if (url.pathname === "/v1/events" && request.method === "POST") {
      return handleEvents(request, env, url.hostname);
    }

    if (url.pathname === "/v1/referral/redeem" && request.method === "POST") {
      return handleReferralRedeem(request, env, url.hostname);
    }
    if (url.pathname === "/v1/me" && request.method === "GET") {
      return handleMe(request, env, url.hostname);
    }
    if (url.pathname === "/v1/stripe/webhook" && request.method === "POST") {
      if (placeholderStripeConfigOffLoopback(env, url.hostname)) {
        console.error("misconfigured: refusing to serve the webhook with placeholder configuration");
        return json({ error: "misconfigured" }, 500);
      }
      return handleStripeWebhook(request, env);
    }
    if (url.pathname === "/v1/billing/checkout" && request.method === "POST") {
      if (placeholderStripeConfigOffLoopback(env, url.hostname)) {
        console.error("misconfigured: refusing to serve billing/checkout with placeholder configuration");
        return json({ error: "misconfigured" }, 500);
      }
      return handleBillingCheckout(request, env, url.hostname);
    }
    if (url.pathname === "/v1/billing/portal" && request.method === "POST") {
      if (placeholderStripeConfigOffLoopback(env, url.hostname)) {
        console.error("misconfigured: refusing to serve billing/portal with placeholder configuration");
        return json({ error: "misconfigured" }, 500);
      }
      return handleBillingPortal(request, env, url.hostname);
    }
    return new Response("Not found", { status: 404 });
  },
};

/**
 * Per-request facts for the single log line. Deliberately closed: only a fixed
 * error kind and a hashed user id can be recorded, so no request content, token,
 * key or upstream detail has a way into the log.
 */
interface RequestTrace {
  userHash: string | null;
  kind: string | null;
}

/** What a validated body yields, or the fixed rejection to answer. */
type Parsed<I> = { ok: true; input: I } | { ok: false; kind: string; status: number; error: string };

/**
 * Everything that differs between the metered endpoints. The pipeline around it (config guards,
 * authentication, body cap, validation, tier, quota, provider, one log line) is shared, so a
 * sibling endpoint cannot end up with a weaker order of checks than /v1/rewrite.
 */
interface Endpoint<I> {
  /** Log event name and quota counter. */
  event: QuotaKind;
  /** The fixed `error` when the whole body is over MAX_BODY_BYTES. */
  bodyTooLargeError: string;
  /** Validates the parsed JSON body: type, non-empty, caps. Runs before tier, quota and provider. */
  validate(parsed: object): Parsed<I>;
  tierRequiredError: string;
  /** Kind and fixed body when the provider fails. */
  providerFailedKind: string;
  providerFailedError: string;
  /** Calls the provider (mock or real) and returns the JSON success body. Throws on failure. */
  run(input: I, env: Env, hostname: string): Promise<Record<string, string>>;
}

const bad = (kind: string, status: number, error: string): { ok: false; kind: string; status: number; error: string } => ({ ok: false, kind, status, error });

const rewriteEndpoint: Endpoint<string> = {
  event: "rewrite",
  bodyTooLargeError: "transcript_too_long",
  validate(parsed) {
    const transcript = (parsed as { transcript?: unknown }).transcript;
    if (typeof transcript !== "string" || transcript.trim().length === 0) return bad("missing_transcript", 400, "missing transcript");
    // Count Unicode code points, not UTF-16 units, so an emoji is one character.
    // The body is already capped at 64 KB, so spreading it is cheap.
    if ([...transcript].length > MAX_TRANSCRIPT_CHARS) return bad("transcript_too_long", 413, "transcript_too_long");
    return { ok: true, input: transcript };
  },
  tierRequiredError: "rewrite requires the Pro tier",
  providerFailedKind: "rewrite_failed",
  providerFailedError: "rewrite failed",
  async run(transcript, env, hostname) {
    const rewritten = chooseProvider(env, hostname) === "mock" ? mockRewrite(transcript) : await rewriteTranscript(transcript, env);
    return { rewritten };
  },
};

interface EditInput {
  instruction: string;
  selection: string;
  context: EditContext | undefined;
}

const codePoints = (text: string): number => [...text].length;
/** At most `max` code points (never splitting a surrogate pair), with no stray edge whitespace. */
const truncate = (text: string, max: number): string => [...text].slice(0, max).join("").trim();

const editEndpoint: Endpoint<EditInput> = {
  event: "edit",
  bodyTooLargeError: "body_too_large",
  validate(parsed) {
    const { instruction, selection, context } = parsed as { instruction?: unknown; selection?: unknown; context?: unknown };
    if (typeof instruction !== "string" || instruction.trim().length === 0) return bad("missing_instruction", 400, "missing instruction");
    if (typeof selection !== "string" || selection.trim().length === 0) return bad("missing_selection", 400, "missing selection");
    if (codePoints(selection) > MAX_EDIT_SELECTION_CHARS) return bad("selection_too_long", 413, "selection_too_long");
    if (codePoints(instruction) > MAX_EDIT_INSTRUCTION_CHARS) return bad("instruction_too_long", 413, "instruction_too_long");

    // `context` is optional (absent or null). When present it must be an object whose known fields
    // are strings; over-long values are truncated, not refused, because a long browser tab title
    // must not cost the user their edit. Unknown fields (here and at the top level) are ignored.
    let checked: EditContext | undefined;
    if (context !== undefined && context !== null) {
      if (typeof context !== "object" || Array.isArray(context)) return bad("invalid_body", 400, "invalid request body");
      const { app, windowTitle } = context as { app?: unknown; windowTitle?: unknown };
      for (const field of [app, windowTitle]) {
        if (field !== undefined && field !== null && typeof field !== "string") return bad("invalid_body", 400, "invalid request body");
      }
      checked = {
        app: typeof app === "string" ? truncate(app, MAX_EDIT_CONTEXT_APP_CHARS) : undefined,
        windowTitle: typeof windowTitle === "string" ? truncate(windowTitle, MAX_EDIT_CONTEXT_WINDOW_TITLE_CHARS) : undefined,
      };
    }
    return { ok: true, input: { instruction, selection, context: checked } };
  },
  tierRequiredError: "edit requires the Pro tier",
  providerFailedKind: "edit_failed",
  providerFailedError: "edit failed",
  async run({ instruction, selection, context }, env, hostname) {
    const edited =
      chooseProvider(env, hostname) === "mock"
        ? mockEdit(instruction, selection)
        : await editSelection(instruction, selection, context, env);
    // The reply keeps the selection's own edge whitespace, whichever provider produced it.
    return { edited: preserveEdgeWhitespace(selection, edited) };
  },
};

interface AskInput {
  instruction: string;
  text?: string;
  title?: string;
  image?: string;
  uiTree?: string;
}

const askEndpoint: Endpoint<AskInput> = {
  event: "ask",
  bodyTooLargeError: "body_too_large",
  validate(parsed) {
    const { instruction, text, title, image, uiTree } = parsed as {
      instruction?: unknown;
      text?: unknown;
      title?: unknown;
      image?: unknown;
      uiTree?: unknown;
    };
    if (typeof instruction !== "string" || instruction.trim().length === 0) return bad("missing_instruction", 400, "missing instruction");
    if (codePoints(instruction) > MAX_ASK_INSTRUCTION_CHARS) return bad("instruction_too_long", 413, "instruction_too_long");
    if (typeof text === "string" && codePoints(text) > MAX_ASK_TEXT_CHARS) return bad("text_too_long", 413, "text_too_long");
    // Base64 is ASCII-only, so the overall 5 MB body cap already bounds how much a client can send;
    // this only rejects a request that could never succeed (malformed base64) before it reaches a
    // paid provider call and consumes the user's quota. Not a format/magic-byte check: whether the
    // bytes are actually a JPEG is left to the provider, matching askQuestion's hardcoded media type.
    if (typeof image === "string" && image.length > 0 && (image.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(image))) {
      return bad("invalid_body", 400, "invalid request body");
    }

    return {
      ok: true,
      input: {
        instruction,
        text: typeof text === "string" ? text : undefined,
        title: typeof title === "string" ? truncate(title, MAX_EDIT_CONTEXT_WINDOW_TITLE_CHARS) : undefined,
        image: typeof image === "string" ? image : undefined,
        uiTree: typeof uiTree === "string" ? truncate(uiTree, MAX_ASK_UI_TREE_CHARS) : undefined,
      },
    };
  },
  tierRequiredError: "ask requires the Pro tier",
  providerFailedKind: "ask_failed",
  providerFailedError: "ask failed",
  async run({ instruction, text, title, image, uiTree }, env, hostname) {
    const answer =
      chooseProvider(env, hostname) === "mock"
        ? mockAsk(instruction, text, title, image, uiTree)
        : await askQuestion(instruction, text, title, image, uiTree, env);
    return { answer };
  },
};

async function handleProtected<I>(request: Request, env: Env, hostname: string, endpoint: Endpoint<I>, maxBodyBytes: number = MAX_BODY_BYTES): Promise<Response> {
  const startedAt = Date.now();
  const trace: RequestTrace = { userHash: null, kind: null };
  let response: Response;
  try {
    response = await serve(request, env, hostname, trace, endpoint, maxBodyBytes);
  } catch {
    // Anything unexpected: a fixed body, never a stack trace or upstream detail.
    response = reject(trace, "internal_error", 500, "internal_error");
  }
  logRequest(endpoint.event, response.status, Date.now() - startedAt, trace);
  return response;
}

async function serve<I>(request: Request, env: Env, hostname: string, trace: RequestTrace, endpoint: Endpoint<I>, maxBodyBytes: number = MAX_BODY_BYTES): Promise<Response> {
  // authenticate() itself refuses to serve when verification is misconfigured (an unknown
  // JWT_VERIFY_MODE, a deployed Worker holding a local-dev or too-short JWT secret, or, in
  // jwks mode, a JWKS URL that is not https on the project's own origin) before it looks at
  // the Authorization header at all. That guard lives there, not here, so every route that
  // authenticates a request shares it and none can be added later without it.
  let user: AuthedUser | null;
  try {
    user = await authenticate(request, env, hostname);
  } catch (error) {
    if (error instanceof MisconfiguredError) {
      console.error(`misconfigured: ${error.reason}`);
      return reject(trace, "misconfigured", 500, "misconfigured");
    }
    if (error instanceof AuthUnavailableError) {
      // The key source failed: the token was not shown to be bad. Same outage answer and log kind
      // as a tier lookup failure, so the client retries later instead of signing the user out.
      return reject(trace, "tier_lookup_failed", 503, "service_unavailable");
    }
    throw error;
  }
  if (!user) return reject(trace, "unauthorized", 401, "unauthorized");
  trace.userHash = await hashUserId(user.id);

  // Validate the body before any upstream call or quota use: a malformed or
  // oversized request must not cost the user allowance or us a lookup.
  const body = await readBodyCapped(request, maxBodyBytes);

  if (body.kind === "too_large") return reject(trace, "body_too_large", 413, endpoint.bodyTooLargeError);
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
  const checked = endpoint.validate(parsed);
  if (!checked.ok) return reject(trace, checked.kind, checked.status, checked.error);

  // A failed tier or quota lookup is an outage, never "free" and never a raw 500.
  // Errors are deliberately swallowed without logging: they may carry upstream details.
  let tier: Tier;
  try {
    tier = await getUserTier(user.id, env);
  } catch {
    return reject(trace, "tier_lookup_failed", 503, "service_unavailable");
  }
  if (tier !== "pro") return reject(trace, "tier_required", 402, endpoint.tierRequiredError);

  let quota: RateLimitResult;
  try {
    quota = await checkAndConsumeQuota(user.id, tier, env, endpoint.event);
  } catch {
    return reject(trace, "quota_store_failed", 503, "service_unavailable");
  }
  if (!quota.allowed) return reject(trace, quota.reason, 429, quota.reason);

  try {
    return json(await endpoint.run(checked.input, env, hostname));
  } catch {
    return reject(trace, endpoint.providerFailedKind, 502, endpoint.providerFailedError);
  }
}

/** First 12 hex chars of SHA-256(user id): enough to correlate, never the id itself. */
async function hashUserId(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(userId));
  return Array.from(new Uint8Array(digest).slice(0, 6), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** One content-free line per request: event, status, latency, error kind, hashed user. */
function logRequest(event: string, status: number, latencyMs: number, trace: RequestTrace): void {
  try {
    console.log(
      JSON.stringify({ event, status, latency_ms: latencyMs, error: trace.kind, user: trace.userHash })
    );
  } catch {
    // Logging must never change the response.
  }
}

function reject(trace: RequestTrace, kind: string, status: number, error: string): Response {
  trace.kind = kind;
  return json({ error }, status);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
