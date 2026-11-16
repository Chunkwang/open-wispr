#!/usr/bin/env node
// Local stand-in for the Stripe API surface this app needs, for development without a Stripe
// account. Dev only: in-memory, no dependencies (node:http and node:crypto), listens on
// 127.0.0.1 only. Companion to scripts/mock-supabase.mjs; follows the same conventions.
//
// The real Stripe API takes `application/x-www-form-urlencoded` bodies (not JSON) with bracket
// nesting (e.g. `metadata[supabase_user_id]=<uuid>`, `line_items[0][price]=<id>`) — that is what
// the `stripe` npm SDK sends, so this mock parses that shape, not JSON, on the routes it serves.
//
// Real Stripe API surface (what the Worker's `stripe` SDK client calls — see src/stripeClient.ts,
// which points the SDK at this server's STRIPE_API_BASE_URL only on a loopback hostname):
//   POST /v1/customers                 form: metadata[supabase_user_id]
//                                       -> 200 {"id":"cus_...","object":"customer","metadata":{...}}
//   POST /v1/checkout/sessions         form: mode, customer, line_items[0][price], line_items[0][quantity],
//                                             subscription_data[metadata][supabase_user_id], success_url, cancel_url
//                                       -> 200 {"id":"cs_...","object":"checkout.session","url":"...",...}
//   POST /v1/billing_portal/sessions   form: customer, return_url
//                                       -> 200 {"id":"bps_...","object":"billing_portal.session","url":"...",...}
//
// Dev-only routes (a loopback Host header only, else 404), for exercising the Worker's real
// webhook path end to end without a Stripe account:
//   POST /__dev/complete-checkout  {"session_id","status"?}     "completes" a Checkout Session:
//     creates a subscription (default status "active") from the session's stored
//     subscription_data.metadata, signs a customer.subscription.created event with the shared
//     STRIPE_WEBHOOK_SECRET (the same HMAC-SHA256 timestamped scheme stripe.webhooks.constructEvent
//     verifies), and POSTs it straight to WORKER_URL + /v1/stripe/webhook — the same request a real
//     Stripe webhook delivery would make. Returns {"ok", "webhook_status", "webhook_body"} so a
//     manual step or a script can see whether the Worker accepted it.
//   POST /__dev/fire-webhook  {"type","supabase_user_id","status"?,"subscription_id"?,"customer_id"?}
//     Lower-level: builds and signs a customer.subscription.<created|updated|deleted> event
//     directly (no Checkout Session needed) and fires it the same way, for exercising a status
//     (e.g. past_due, canceled) or event type without an unrelated checkout flow. Same response shape.
//   POST /__dev/fail    {"route":"customers|checkout_sessions|portal_sessions|any","mode":"503|500|drop|hang","times":n}
//   POST /__dev/reset   forgets everything, as if the mock had restarted
//   GET  /__dev/session?id=<cs_id>   the stored Checkout Session, for debugging (404 if unknown)
//
// Usage:
//   node scripts/mock-stripe.mjs
//   PORT=54323 WORKER_URL=http://127.0.0.1:8787 node scripts/mock-stripe.mjs   (PORT=0 picks a free port)
//
// Environment (all optional except the webhook secret):
//   PORT                  listen port (default 54323)
//   WORKER_URL            base URL of the running Worker (`wrangler dev`); env, else .dev.vars'
//                          implicit default http://127.0.0.1:8787 (there is no .dev.vars entry for
//                          this — the Worker's own port is not itself configurable there)
//   STRIPE_WEBHOOK_SECRET  shared secret used to sign fired webhook events; env, else .dev.vars.
//                          Must match the Worker's STRIPE_WEBHOOK_SECRET or its signature check fails.
//   MOCK_FAIL              "503" answers every non-dev request with 503; "drop" closes the connection

import { createHmac, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { readDevVar } from "./lib/dev-vars.mjs";

const LOOPBACK_HOSTNAMES = new Set(["127.0.0.1", "localhost"]);
const MAX_BODY_BYTES = 16 * 1024;

function die(message) {
  process.stderr.write(`mock-stripe: ${message}\n`);
  process.exit(1);
}

const port = process.env.PORT === undefined || process.env.PORT === "" ? 54323 : Number(process.env.PORT);
if (!Number.isInteger(port) || port < 0 || port > 65535) die(`PORT must be 0-65535, got "${process.env.PORT}"`);

const workerUrl = (process.env.WORKER_URL || "http://127.0.0.1:8787").replace(/\/+$/, "");

const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET || readDevVar("STRIPE_WEBHOOK_SECRET");
if (!webhookSecret) {
  die("STRIPE_WEBHOOK_SECRET is not set. Export it, or copy .dev.vars.example to .dev.vars in backend/proxy.");
}

const failMode = process.env.MOCK_FAIL;
if (failMode !== undefined && failMode !== "" && failMode !== "503" && failMode !== "drop") {
  die(`MOCK_FAIL must be "503" or "drop", got "${failMode}"`);
}

// ---------------------------------------------------------------------------
// State (in memory; POST /__dev/reset clears it)
// ---------------------------------------------------------------------------

/** id -> { id, metadata } */
const customers = new Map();
/** id -> { id, customerId, priceId, subscriptionMetadata, successUrl, cancelUrl, status } */
const checkoutSessions = new Map();
/** id -> { id, customerId, returnUrl } */
const portalSessions = new Map();
/** id -> { id, customerId, status, metadata } */
const subscriptions = new Map();
/** injected failures: [{ route, mode, times }] */
const failRules = [];

function resetState() {
  customers.clear();
  checkoutSessions.clear();
  portalSessions.clear();
  subscriptions.clear();
  failRules.length = 0;
}

const randomId = (prefix) => `${prefix}_${randomBytes(12).toString("hex")}`;

// ---------------------------------------------------------------------------
// application/x-www-form-urlencoded with bracket nesting (what the `stripe` SDK sends)
// ---------------------------------------------------------------------------

/** Splits `a[b][c]` into ["a", "b", "c"]; a bare key with no brackets is ["a"]. */
function keyPath(rawKey) {
  const match = /^([^[\]]+)((?:\[[^\]]*\])*)$/.exec(rawKey);
  if (!match) return [rawKey];
  const path = [match[1]];
  const re = /\[([^\]]*)\]/g;
  let segment;
  while ((segment = re.exec(match[2]))) path.push(segment[1]);
  return path;
}

function setPath(root, path, value) {
  let node = root;
  for (let i = 0; i < path.length; i++) {
    const key = path[i] === "" ? node.length : path[i]; // "[]" (empty segment) appends
    if (i === path.length - 1) {
      node[key] = value;
    } else {
      const nextIsIndex = path[i + 1] === "" || /^\d+$/.test(path[i + 1]);
      if (node[key] === undefined || typeof node[key] !== "object") node[key] = nextIsIndex ? [] : {};
      node = node[key];
    }
  }
}

/** Parses a form-urlencoded body into a nested object, Stripe SDK style. */
function parseFormBody(text) {
  const root = {};
  if (!text) return root;
  for (const pair of text.split("&")) {
    if (!pair) continue;
    const eq = pair.indexOf("=");
    const rawKey = eq === -1 ? pair : pair.slice(0, eq);
    const rawVal = eq === -1 ? "" : pair.slice(eq + 1);
    const key = decodeURIComponent(rawKey.replace(/\+/g, " "));
    const val = decodeURIComponent(rawVal.replace(/\+/g, " "));
    setPath(root, keyPath(key), val);
  }
  return root;
}

/** Reads the body up to MAX_BODY_BYTES and parses it as form-urlencoded. { ok, value } or { ok:false }. */
function readForm(req) {
  return new Promise((resolve) => {
    let size = 0;
    let tooLarge = false;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) tooLarge = true;
      else chunks.push(chunk);
    });
    req.on("end", () => {
      if (tooLarge) return resolve({ ok: false });
      resolve({ ok: true, value: parseFormBody(Buffer.concat(chunks).toString("utf8")) });
    });
    req.on("error", () => resolve({ ok: false }));
  });
}

/** Reads a JSON body (the dev routes use JSON, like mock-supabase's). */
function readJson(req) {
  return new Promise((resolve) => {
    let size = 0;
    let tooLarge = false;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) tooLarge = true;
      else chunks.push(chunk);
    });
    req.on("end", () => {
      if (tooLarge) return resolve({ ok: false });
      try {
        resolve({ ok: true, value: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
      } catch {
        resolve({ ok: false });
      }
    });
    req.on("error", () => resolve({ ok: false }));
  });
}

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);

function send(res, status, body, headers = {}) {
  const payload = body === undefined ? "" : JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(payload), ...headers });
  res.end(payload);
}

function stripeError(res, status, message, type = "invalid_request_error") {
  return send(res, status, { error: { type, message } });
}

// ---------------------------------------------------------------------------
// Injected failures (same shape as mock-supabase.mjs's)
// ---------------------------------------------------------------------------

function routeName(pathname) {
  switch (pathname) {
    case "/v1/customers":
      return "customers";
    case "/v1/checkout/sessions":
      return "checkout_sessions";
    case "/v1/billing_portal/sessions":
      return "portal_sessions";
    default:
      return null;
  }
}

function takeInjectedFailure(route) {
  const rule = failRules.find((r) => r.times > 0 && (r.route === "any" || r.route === route));
  if (!rule) return null;
  rule.times -= 1;
  return rule.mode;
}

function applyFailure(mode, req, res) {
  switch (mode) {
    case "drop":
      req.socket.destroy();
      return;
    case "hang":
      return; // never answers; the server tears the socket down on shutdown
    case "503":
      return stripeError(res, 503, "mock outage", "api_error");
    case "500":
      return stripeError(res, 500, "mock failure", "api_error");
  }
}

// ---------------------------------------------------------------------------
// Stripe-shaped routes
// ---------------------------------------------------------------------------

function requireAuth(req, res) {
  const header = req.headers["authorization"] ?? "";
  if (!header.startsWith("Bearer ") || header.length <= "Bearer ".length) {
    stripeError(res, 401, "You did not provide an API key.", "authentication_error");
    return false;
  }
  return true;
}

async function handleCustomers(req, res) {
  if (!requireAuth(req, res)) return;
  if (req.method !== "POST") return send(res, 405, { error: { message: "method not allowed" } });
  const parsed = await readForm(req);
  if (!parsed.ok) return stripeError(res, 400, "could not parse request body");
  const metadata = isObject(parsed.value.metadata) ? parsed.value.metadata : {};
  const id = randomId("cus");
  const customer = { id, object: "customer", metadata };
  customers.set(id, customer);
  return send(res, 200, customer);
}

async function handleCheckoutSessions(req, res) {
  if (!requireAuth(req, res)) return;
  if (req.method !== "POST") return send(res, 405, { error: { message: "method not allowed" } });
  const parsed = await readForm(req);
  if (!parsed.ok) return stripeError(res, 400, "could not parse request body");
  const body = parsed.value;
  const customerId = typeof body.customer === "string" ? body.customer : "";
  if (!customers.has(customerId)) return stripeError(res, 400, `No such customer: '${customerId}'`);
  const subscriptionMetadata = isObject(body.subscription_data) && isObject(body.subscription_data.metadata) ? body.subscription_data.metadata : {};
  const priceId = Array.isArray(body.line_items) && body.line_items[0] ? body.line_items[0].price : undefined;
  const id = randomId("cs");
  const session = {
    id,
    customerId,
    priceId,
    subscriptionMetadata,
    successUrl: typeof body.success_url === "string" ? body.success_url : "",
    cancelUrl: typeof body.cancel_url === "string" ? body.cancel_url : "",
    status: "open",
  };
  checkoutSessions.set(id, session);
  return send(res, 200, {
    id,
    object: "checkout.session",
    mode: "subscription",
    customer: customerId,
    subscription: null,
    status: "open",
    // A real page a developer can open; POST /__dev/complete-checkout is how a test "completes" it.
    url: `http://127.0.0.1:${actualPort}/__dev/checkout-page?session=${id}`,
  });
}

async function handlePortalSessions(req, res) {
  if (!requireAuth(req, res)) return;
  if (req.method !== "POST") return send(res, 405, { error: { message: "method not allowed" } });
  const parsed = await readForm(req);
  if (!parsed.ok) return stripeError(res, 400, "could not parse request body");
  const body = parsed.value;
  const customerId = typeof body.customer === "string" ? body.customer : "";
  if (!customers.has(customerId)) return stripeError(res, 400, `No such customer: '${customerId}'`);
  const id = randomId("bps");
  const returnUrl = typeof body.return_url === "string" ? body.return_url : "";
  portalSessions.set(id, { id, customerId, returnUrl });
  return send(res, 200, {
    id,
    object: "billing_portal.session",
    customer: customerId,
    return_url: returnUrl,
    url: `http://127.0.0.1:${actualPort}/__dev/portal-page?session=${id}`,
  });
}

// ---------------------------------------------------------------------------
// Signing and firing a webhook event, exactly as stripe.webhooks.constructEventAsync verifies it:
// Stripe-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<payload>" with the webhook secret>
// ---------------------------------------------------------------------------

function signEvent(payload) {
  const timestamp = Math.floor(Date.now() / 1000);
  const signedPayload = `${timestamp}.${payload}`;
  const signature = createHmac("sha256", webhookSecret).update(signedPayload).digest("hex");
  return `t=${timestamp},v1=${signature}`;
}

function buildEvent(type, subscription) {
  return {
    id: randomId("evt"),
    object: "event",
    api_version: "2024-11-01",
    created: Math.floor(Date.now() / 1000),
    livemode: false,
    type,
    data: { object: subscription },
  };
}

/** POSTs a signed event straight to the Worker's webhook route. Returns { status, body } (body parsed as JSON if possible). */
async function fireWebhook(type, subscription) {
  const payload = JSON.stringify(buildEvent(type, subscription));
  const signature = signEvent(payload);
  const res = await fetch(`${workerUrl}/v1/stripe/webhook`, {
    method: "POST",
    headers: { "content-type": "application/json", "stripe-signature": signature },
    body: payload,
  });
  const text = await res.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return { status: res.status, body };
}

// ---------------------------------------------------------------------------
// Dev-only routes
// ---------------------------------------------------------------------------

function hostnameOf(hostHeader) {
  const host = String(hostHeader ?? "");
  try {
    return new URL(`http://${host}`).hostname;
  } catch {
    return "";
  }
}

const SUBSCRIPTION_STATUSES = new Set(["active", "trialing", "past_due", "canceled"]);
const EVENT_TYPES = new Set(["customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"]);

async function handleDev(req, res, url) {
  const notFound = () => send(res, 404, { error: { message: "not found" } });

  if (req.method === "GET" && url.pathname === "/__dev/session") {
    const id = url.searchParams.get("id") ?? "";
    const session = checkoutSessions.get(id);
    return session ? send(res, 200, session) : notFound();
  }
  if (req.method !== "POST") return notFound();

  if (url.pathname === "/__dev/reset") {
    resetState();
    return send(res, 200, { ok: true });
  }

  const parsed = await readJson(req);
  if (!parsed.ok || !isObject(parsed.value)) return send(res, 400, { error: "invalid JSON body" });
  const body = parsed.value;

  if (url.pathname === "/__dev/fail") {
    const routes = new Set(["customers", "checkout_sessions", "portal_sessions", "any"]);
    const modes = new Set(["503", "500", "drop", "hang"]);
    const times = body.times === undefined ? 1 : body.times;
    if (!routes.has(body.route) || !modes.has(body.mode) || !Number.isInteger(times) || times < 1) {
      return send(res, 400, { error: 'need {"route": customers|checkout_sessions|portal_sessions|any, "mode": 503|500|drop|hang, "times": n>=1}' });
    }
    failRules.push({ route: body.route, mode: body.mode, times });
    return send(res, 200, { ok: true });
  }

  if (url.pathname === "/__dev/complete-checkout") {
    const session = typeof body.session_id === "string" ? checkoutSessions.get(body.session_id) : undefined;
    if (!session) return send(res, 400, { error: "unknown session_id" });
    const status = body.status === undefined ? "active" : body.status;
    if (!SUBSCRIPTION_STATUSES.has(status)) return send(res, 400, { error: 'status must be one of "active","trialing","past_due","canceled"' });
    session.status = "complete";
    const subId = randomId("sub");
    const subscription = { id: subId, object: "subscription", customer: session.customerId, status, metadata: session.subscriptionMetadata };
    subscriptions.set(subId, subscription);
    const { status: webhookStatus, body: webhookBody } = await fireWebhook("customer.subscription.created", subscription);
    return send(res, 200, { ok: webhookStatus >= 200 && webhookStatus < 300, subscription_id: subId, webhook_status: webhookStatus, webhook_body: webhookBody });
  }

  if (url.pathname === "/__dev/fire-webhook") {
    const type = body.type;
    const status = body.status === undefined ? "active" : body.status;
    const supabaseUserId = body.supabase_user_id;
    if (!EVENT_TYPES.has(type)) return send(res, 400, { error: `type must be one of ${[...EVENT_TYPES].join(", ")}` });
    if (status !== undefined && !SUBSCRIPTION_STATUSES.has(status)) return send(res, 400, { error: 'status must be one of "active","trialing","past_due","canceled"' });
    const subId = typeof body.subscription_id === "string" ? body.subscription_id : randomId("sub");
    const customerId = typeof body.customer_id === "string" ? body.customer_id : randomId("cus");
    const metadata = supabaseUserId === undefined ? {} : { supabase_user_id: supabaseUserId };
    const subscription = { id: subId, object: "subscription", customer: customerId, status, metadata };
    const { status: webhookStatus, body: webhookBody } = await fireWebhook(type, subscription);
    return send(res, 200, { ok: webhookStatus >= 200 && webhookStatus < 300, webhook_status: webhookStatus, webhook_body: webhookBody });
  }

  return notFound();
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

let actualPort = port; // set once listening; used to build session URLs

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://127.0.0.1");
  process.stdout.write(`${req.method} ${url.pathname}\n`);

  if (url.pathname.startsWith("/__dev/")) {
    if (!LOOPBACK_HOSTNAMES.has(hostnameOf(req.headers["host"]))) return send(res, 404, { error: { message: "not found" } });
    return handleDev(req, res, url);
  }

  if (failMode === "drop") return req.socket.destroy();
  if (failMode === "503") return stripeError(res, 503, "mock outage", "api_error");

  const injected = takeInjectedFailure(routeName(url.pathname));
  if (injected) return applyFailure(injected, req, res);

  if (url.pathname === "/v1/customers") return handleCustomers(req, res);
  if (url.pathname === "/v1/checkout/sessions") return handleCheckoutSessions(req, res);
  if (url.pathname === "/v1/billing_portal/sessions") return handlePortalSessions(req, res);
  return stripeError(res, 404, "Unrecognized request URL.", "invalid_request_error");
});

server.listen(port, "127.0.0.1", () => {
  actualPort = server.address().port;
  process.stdout.write(`mock-stripe listening on http://127.0.0.1:${actualPort} (worker: ${workerUrl}${failMode ? `, MOCK_FAIL=${failMode}` : ""})\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    server.closeAllConnections();
  });
}
