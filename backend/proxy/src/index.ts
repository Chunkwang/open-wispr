import type { Env, Tier } from "./types";
import { authenticate } from "./auth";
import { getUserTier } from "./tier";
import { checkAndConsumeQuota, type RateLimitResult } from "./rateLimit";
import { rewriteTranscript } from "./claude";
import { chooseProvider, mockRewrite } from "./llmProvider";
import { handleStripeWebhook } from "./stripeWebhook";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/v1/rewrite" && request.method === "POST") {
      return handleRewrite(request, env, url.hostname);
    }
    if (url.pathname === "/v1/stripe/webhook" && request.method === "POST") {
      return handleStripeWebhook(request, env);
    }
    return new Response("Not found", { status: 404 });
  },
};

async function handleRewrite(request: Request, env: Env, hostname: string): Promise<Response> {
  const user = await authenticate(request, env);
  if (!user) return json({ error: "unauthorized" }, 401);

  // A failed tier or quota lookup is an outage, never "free" and never a raw 500.
  // Errors are deliberately swallowed without logging: they may carry upstream details.
  let tier: Tier;
  try {
    tier = await getUserTier(user.id, env);
  } catch {
    return json({ error: "service_unavailable" }, 503);
  }
  if (tier !== "pro") return json({ error: "rewrite requires the Pro tier" }, 402);

  let quota: RateLimitResult;
  try {
    quota = await checkAndConsumeQuota(user.id, tier, env);
  } catch {
    return json({ error: "service_unavailable" }, 503);
  }
  if (!quota.allowed) return json({ error: quota.reason }, 429);

  let body: { transcript?: unknown };
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid request body" }, 400);
  }
  if (typeof body.transcript !== "string" || body.transcript.length === 0) {
    return json({ error: "missing transcript" }, 400);
  }

  try {
    const rewritten =
      chooseProvider(env, hostname) === "mock"
        ? mockRewrite(body.transcript)
        : await rewriteTranscript(body.transcript, env);
    return json({ rewritten });
  } catch {
    return json({ error: "rewrite failed" }, 502);
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
