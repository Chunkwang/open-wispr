import type { Env } from "./types";
import { MAX_BODY_BYTES } from "./types";
import { readBodyCapped } from "./httpBody";
import { checkAndConsumeQuota, type RateLimitResult } from "./rateLimit";

export const ALLOWED_EVENTS = new Set([
  "dictation_completed",
  "rewrite_invoked",
  "subscription_tier_changed",
  "before_after_shared",
  "referral_sent",
]);

interface EventRequest {
  event?: unknown;
}

/**
 * Handles POST /v1/events
 * Anonymous counter endpoint: intentionally takes no auth token, by design (a dictation
 * completion must be countable even signed out, and adding a Bearer requirement here would
 * be a product change, not a security fix).
 *
 * Rules:
 *  - Event name must be one of the 5 allowed v1 event counters.
 *  - Contains no user identifier, token, or payload data. The caller's IP (or, failing that,
 *    the request hostname) is used only to pick a rate-limit bucket below; it is never stored,
 *    logged, or returned, matching the same "counts only, not even the key" contract as the
 *    per-user QuotaCounter Durable Object (see quotaCounter.ts).
 *  - Rate-limited per source (see EVENTS_LIMITS in types.ts): being unauthenticated, this is
 *    otherwise a free, unmetered cost/spam vector open to anyone on the internet.
 *  - Body is capped at MAX_BODY_BYTES, same as every other endpoint: 413 before anything else.
 *  - Answers 200 OK for allowed events, 400 for unknown/invalid events.
 */
export async function handleEvents(request: Request, env: Env, hostname: string): Promise<Response> {
  const bodyResult = await readBodyCapped(request, MAX_BODY_BYTES);
  if (bodyResult.kind === "too_large") return json({ ok: false, error: "body_too_large" }, 413);
  if (bodyResult.kind === "bad_encoding") return json({ ok: false, error: "invalid_json" }, 400);

  let body: EventRequest;
  try {
    body = JSON.parse(bodyResult.text) as EventRequest;
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const name = typeof body.event === "string" ? body.event.trim() : "";
  if (!name || !ALLOWED_EVENTS.has(name)) {
    return json({ ok: false, error: "invalid_event" }, 400);
  }

  let quota: RateLimitResult;
  try {
    quota = await checkAndConsumeQuota(clientKey(request, hostname), "free", env, "events");
  } catch {
    return json({ ok: false, error: "service_unavailable" }, 503);
  }
  if (!quota.allowed) {
    return json({ ok: false, error: quota.reason }, 429);
  }

  return json({ ok: true, recorded: name }, 200);
}

/**
 * The bucket a request's rate limit is charged to: the caller's IP when Cloudflare has set one
 * (every request on the deployed Worker), else the request's own hostname (local dev, tests, or
 * any runtime that strips the header) so the endpoint still fails closed to *some* shared limit
 * rather than silently going unmetered.
 */
function clientKey(request: Request, hostname: string): string {
  const ip = request.headers.get("cf-connecting-ip")?.trim();
  return ip ? `ip:${ip}` : `host:${hostname}`;
}

function json(data: { ok: boolean; error?: string; recorded?: string }, status: number): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}
