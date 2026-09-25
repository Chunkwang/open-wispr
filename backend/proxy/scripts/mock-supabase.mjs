#!/usr/bin/env node
// Local stand-in for the two Supabase PostgREST calls the Worker makes today.
// Dev only: in-memory, no auth checking beyond "headers are present", no
// dependencies. Listens on 127.0.0.1 only.
//
//   GET   /rest/v1/profiles?id=eq.<uuid>&select=tier  -> [{"tier":"pro"}]
//   PATCH /rest/v1/profiles?id=eq.<uuid>  {"tier":"free"|"pro"}  (Stripe webhook)
//
// Usage:
//   node scripts/mock-supabase.mjs
//   PORT=54322 MOCK_TIER=free node scripts/mock-supabase.mjs
//
// MOCK_TIER is the tier for any user not yet PATCHed (default "pro").
// MOCK_FAIL simulates an outage: "503" answers every request with 503, "drop"
// closes the connection without answering. Unset (default) behaves normally.

import { createServer } from "node:http";

const TIERS = new Set(["free", "pro"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 4096;

const port = Number(process.env.PORT ?? 54321);
const defaultTier = process.env.MOCK_TIER ?? "pro";
if (!Number.isInteger(port) || port <= 0 || port > 65535) {
  process.stderr.write(`mock-supabase: PORT must be 1-65535, got "${process.env.PORT}"\n`);
  process.exit(1);
}
if (!TIERS.has(defaultTier)) {
  process.stderr.write(`mock-supabase: MOCK_TIER must be "free" or "pro", got "${defaultTier}"\n`);
  process.exit(1);
}

const failMode = process.env.MOCK_FAIL;
if (failMode !== undefined && failMode !== "" && failMode !== "503" && failMode !== "drop") {
  process.stderr.write(`mock-supabase: MOCK_FAIL must be "503" or "drop", got "${failMode}"\n`);
  process.exit(1);
}

/** user id (lowercase) -> tier */
const tiers = new Map();

function send(res, status, body) {
  const payload = body === undefined ? "" : JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(payload) });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

// Returns the uuid from an `id=eq.<uuid>` filter, or null if absent/invalid.
function userIdFilter(params) {
  const value = params.get("id") ?? "";
  if (!value.startsWith("eq.")) return null;
  const id = value.slice(3);
  return UUID.test(id) ? id.toLowerCase() : null;
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://127.0.0.1");
  // Log method and route only: no query string, headers or bodies.
  process.stdout.write(`${req.method} ${url.pathname}\n`);

  if (failMode === "drop") return req.socket.destroy();
  if (failMode === "503") return send(res, 503, { message: "mock outage" });

  if (url.pathname !== "/rest/v1/profiles") return send(res, 404, { message: "not found" });
  if (!req.headers["apikey"] || !req.headers["authorization"]) {
    return send(res, 401, { message: "No API key found in request", hint: "No `apikey` request header or url param was found." });
  }

  const id = userIdFilter(url.searchParams);
  if (!id) return send(res, 400, { message: 'expected an `id=eq.<uuid>` filter with a valid uuid' });

  if (req.method === "GET") {
    return send(res, 200, [{ tier: tiers.get(id) ?? defaultTier }]);
  }

  if (req.method === "PATCH") {
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch {
      return send(res, 400, { message: "invalid JSON body" });
    }
    if (!body || typeof body !== "object" || !TIERS.has(body.tier)) {
      return send(res, 400, { message: 'body must be {"tier":"free"|"pro"}' });
    }
    tiers.set(id, body.tier);
    // PostgREST answers 204 for Prefer: return=minimal (what the Worker sends).
    if (String(req.headers["prefer"] ?? "").includes("return=minimal")) return send(res, 204);
    return send(res, 200, [{ id, tier: body.tier }]);
  }

  return send(res, 405, { message: "method not allowed" });
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`mock-supabase listening on http://127.0.0.1:${port} (default tier: ${defaultTier}${failMode ? `, MOCK_FAIL=${failMode}` : ""})\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
