import type { Env } from "./types";
import { authenticate } from "./auth";
import { getUserTier } from "./tier";
import { checkAndConsumeQuota } from "./rateLimit";
import { rewriteTranscript } from "./claude";
import { handleStripeWebhook } from "./stripeWebhook";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/v1/rewrite" && request.method === "POST") {
      return handleRewrite(request, env);
    }
    if (url.pathname === "/v1/stripe/webhook" && request.method === "POST") {
      return handleStripeWebhook(request, env);
    }
    return new Response("Not found", { status: 404 });
  },
};

async function handleRewrite(request: Request, env: Env): Promise<Response> {
  const user = await authenticate(request, env);
  if (!user) return json({ error: "unauthorized" }, 401);

  const tier = await getUserTier(user.id, env);
  if (tier !== "pro") return json({ error: "rewrite requires the Pro tier" }, 402);

  const quota = await checkAndConsumeQuota(user.id, tier, env);
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
    const rewritten = await rewriteTranscript(body.transcript, env);
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
