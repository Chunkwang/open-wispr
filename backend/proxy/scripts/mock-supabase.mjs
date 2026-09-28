#!/usr/bin/env node
// Local stand-in for Supabase, for development without an account. Dev only:
// in-memory, no dependencies (node:http and node:crypto), listens on 127.0.0.1 only.
//
// PostgREST (what the Worker calls):
//   GET   /rest/v1/profiles?id=eq.<uuid>&select=tier            -> [{"tier":"pro"}]
//   GET   /rest/v1/profiles?referral_code=eq.<code>&select=id   -> [{"id":<uuid>}] or []  (referral.ts)
//   PATCH /rest/v1/profiles?id=eq.<uuid>  {"tier":"free"|"pro"}  (Stripe webhook)
//   GET   /rest/v1/referrals?referee_id=eq.<uuid>&select=id     -> [{"id":<uuid>}] or []  (referral.ts)
//   POST  /rest/v1/referrals  {"referrer_id","referee_id","code"}  -> 201 [{"id",...}] (referral.ts)
//
// GoTrue email-code sign-in (what the macOS client calls; docs/auth-design.md section 2):
//   POST /auth/v1/otp                             {"email","create_user":true}  -> 200 {}
//   POST /auth/v1/verify                          {"type":"email","email","token"} -> 200 session
//   POST /auth/v1/token?grant_type=refresh_token  {"refresh_token"} -> 200 session (rotated)
//   POST /auth/v1/logout?scope=local|global|others   Authorization: Bearer <access> -> 204
//
// Dev-only routes (a loopback Host header only, else 404):
//   GET  /__dev/last-code?email=<e>   -> {"code":"123456"} or 404
//   POST /__dev/fail    {"route":"otp|verify|token|logout|profiles|referrals|any","mode":"503|429|500|drop|hang","times":n}
//   POST /__dev/revoke  {"email"}     kills that user's sessions and refresh tokens
//   POST /__dev/reset                 forgets everything, as if the mock had restarted
//   POST /__dev/set-referral-code  {"id","code"}  gives a profile a known referral_code, so a
//                                   test can redeem it without guessing the auto-generated value
//
// Usage:
//   node scripts/mock-supabase.mjs
//   PORT=54322 MOCK_TIER=free node scripts/mock-supabase.mjs        (PORT=0 picks a free port)
//
// Environment (all optional):
//   PORT                       listen port (default 54321)
//   SUPABASE_URL               token issuer is ${SUPABASE_URL}/auth/v1; env, else .dev.vars, else http://127.0.0.1:<port>
//   SUPABASE_JWT_SECRET        HS256 signing key; env, else .dev.vars. Must start with "local-dev-" or the mock exits.
//   MOCK_TIER                  tier for a user not yet PATCHed (default "pro")
//   MOCK_FAIL                  "503" answers every non-dev request with 503; "drop" closes the connection
//   MOCK_OTP_RESEND_SECONDS    minimum gap between codes for one email (default 60; 0 disables the limit)
//   MOCK_OTP_TTL_SECONDS       code lifetime (default 600)
//   MOCK_FIXED_CODE            always issue this code (6 to 10 digits) instead of a random one
//   MOCK_MAX_VERIFY_ATTEMPTS   wrong tries per email before a lockout (default 5)
//   MOCK_LOCKOUT_SECONDS       lockout length (default 60)
//   MOCK_ACCESS_TTL_SECONDS    access token lifetime (default 3600)
//   MOCK_JWT_MODE              "hs256" (default) signs with SUPABASE_JWT_SECRET; "es256" signs with a P-256 key generated
//                              at start-up (kid mock-es256-1) and serves it at GET /auth/v1/.well-known/jwks.json, for
//                              running the Worker with JWT_VERIFY_MODE=jwks. In hs256 mode that endpoint serves {"keys":[]}.
//
// The mock prints "mock-supabase: code for <email> is <code>" to stdout. That line
// is the one place a secret is printed, and it exists only in this dev mock.

import { createHash, createHmac, generateKeyPairSync, randomBytes, randomInt, randomUUID, sign as cryptoSign, timingSafeEqual, verify as cryptoVerify } from "node:crypto";
import { createServer } from "node:http";
import { readDevVar } from "./lib/dev-vars.mjs";

const TIERS = new Set(["free", "pro"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_BODY_BYTES = 4096;
/** UUID v5 namespace for user ids: the RFC 4122 DNS namespace, name = lowercased email. */
const USER_NAMESPACE = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
const LOOPBACK_HOSTNAMES = new Set(["127.0.0.1", "localhost"]);

function die(message) {
  process.stderr.write(`mock-supabase: ${message}\n`);
  process.exit(1);
}

function intEnv(name, fallback, min) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min) die(`${name} must be an integer >= ${min}, got "${raw}"`);
  return value;
}

// ---------------------------------------------------------------------------
// Configuration (read once at startup)
// ---------------------------------------------------------------------------

const port = process.env.PORT === undefined || process.env.PORT === "" ? 54321 : Number(process.env.PORT);
if (!Number.isInteger(port) || port < 0 || port > 65535) die(`PORT must be 0-65535, got "${process.env.PORT}"`);

const defaultTier = process.env.MOCK_TIER ?? "pro";
if (!TIERS.has(defaultTier)) die(`MOCK_TIER must be "free" or "pro", got "${defaultTier}"`);

const failMode = process.env.MOCK_FAIL;
if (failMode !== undefined && failMode !== "" && failMode !== "503" && failMode !== "drop") {
  die(`MOCK_FAIL must be "503" or "drop", got "${failMode}"`);
}

const resendSeconds = intEnv("MOCK_OTP_RESEND_SECONDS", 60, 0);
const otpTtlSeconds = intEnv("MOCK_OTP_TTL_SECONDS", 600, 1);
const maxVerifyAttempts = intEnv("MOCK_MAX_VERIFY_ATTEMPTS", 5, 1);
const lockoutSeconds = intEnv("MOCK_LOCKOUT_SECONDS", 60, 1);
const accessTtlSeconds = intEnv("MOCK_ACCESS_TTL_SECONDS", 3600, 1);

const fixedCode = process.env.MOCK_FIXED_CODE || undefined;
if (fixedCode !== undefined && !/^\d{6,10}$/.test(fixedCode)) die("MOCK_FIXED_CODE must be 6 to 10 digits");

const jwtMode = process.env.MOCK_JWT_MODE || "hs256";
if (jwtMode !== "hs256" && jwtMode !== "es256") die(`MOCK_JWT_MODE must be "hs256" or "es256", got "${jwtMode}"`);

// hs256 mode needs the shared secret (and refuses anything that is not a local-dev value);
// es256 mode signs with a throwaway key pair and needs no secret.
const jwtSecret = process.env.SUPABASE_JWT_SECRET || readDevVar("SUPABASE_JWT_SECRET");
if (jwtMode === "hs256") {
  if (!jwtSecret) die("SUPABASE_JWT_SECRET is not set. Export it, or copy .dev.vars.example to .dev.vars in backend/proxy.");
  if (!jwtSecret.startsWith("local-dev-")) {
    die('refusing to sign with a secret that does not start with "local-dev-" (never use a real Supabase JWT secret here)');
  }
}
const ES_KID = "mock-es256-1";
const esKeys = jwtMode === "es256" ? generateKeyPairSync("ec", { namedCurve: "P-256" }) : null;
const jwks = { keys: esKeys ? [{ ...esKeys.publicKey.export({ format: "jwk" }), kid: ES_KID, alg: "ES256", use: "sig" }] : [] };
const supabaseUrl = (process.env.SUPABASE_URL || readDevVar("SUPABASE_URL") || `http://127.0.0.1:${port || 54321}`).replace(/\/+$/, "");
const issuer = `${supabaseUrl}/auth/v1`;

// ---------------------------------------------------------------------------
// State (in memory; POST /__dev/reset clears it)
// ---------------------------------------------------------------------------

/** user id (lowercase) -> tier, for users PATCHed through the Worker's webhook path */
const tiers = new Map();
/** referral_code (lowercase) -> profile id, seeded by POST /__dev/set-referral-code */
const referralCodes = new Map();
/** referrals rows recorded through POST /rest/v1/referrals: { id, referrer_id, referee_id, code } */
const referrals = [];
/** email -> { code, expiresAt } for a code that can still be redeemed (a new code replaces it) */
const activeCodes = new Map();
/** email -> the last code issued, even after it was used or expired (for GET /__dev/last-code) */
const lastCodes = new Map();
/** email -> time of the last send, for the resend limit */
const lastSent = new Map();
/** email -> { wrong, lockedUntil } */
const verifyAttempts = new Map();
/** session id -> { userId, email } */
const sessions = new Map();
/** refresh token -> { sid, used } ; a used (rotated-out) token stays so reuse can be detected */
const refreshTokens = new Map();
/** injected failures: [{ route, mode, times }] */
const failRules = [];

function resetState() {
  tiers.clear();
  referralCodes.clear();
  referrals.length = 0;
  activeCodes.clear();
  lastCodes.clear();
  lastSent.clear();
  verifyAttempts.clear();
  sessions.clear();
  refreshTokens.clear();
  failRules.length = 0;
}

const now = () => Date.now();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function send(res, status, body, headers = {}) {
  const payload = body === undefined ? "" : JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(payload), ...headers });
  res.end(payload);
}

/** GoTrue error shape: {"code":<http>,"error_code":"<x>","msg":"<text>"}. */
function authError(res, status, errorCode, msg, headers) {
  return send(res, status, { code: status, error_code: errorCode, msg }, headers);
}

const NO_API_KEY = { message: "No API key found in request", hint: "No `apikey` request header or url param was found." };

/** Reads a JSON body up to MAX_BODY_BYTES. Resolves { ok, value } or { ok: false, tooLarge }. */
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
      if (tooLarge) return resolve({ ok: false, tooLarge: true });
      try {
        resolve({ ok: true, value: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
      } catch {
        resolve({ ok: false, tooLarge: false });
      }
    });
    req.on("error", () => resolve({ ok: false, tooLarge: false }));
  });
}

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);

/** The trimmed, lowercased email, or null when it is not a plausible address. */
function normaliseEmail(value) {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (email.length === 0 || email.length > 254 || !EMAIL.test(email)) return null;
  return email;
}

function uuidV5(namespace, name) {
  const bytes = createHash("sha1")
    .update(Buffer.from(namespace.replace(/-/g, ""), "hex"))
    .update(name, "utf8")
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

const userIdFor = (email) => uuidV5(USER_NAMESPACE, email);

function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
}

/** 12 characters of base64url, like a GoTrue refresh token. */
const newRefreshToken = () => randomBytes(9).toString("base64url");

const b64url = (input) => Buffer.from(input).toString("base64url");

function signAccessToken(payload) {
  const head = b64url(JSON.stringify(esKeys ? { alg: "ES256", typ: "JWT", kid: ES_KID } : { alg: "HS256", typ: "JWT" }));
  const body = b64url(JSON.stringify(payload));
  const data = `${head}.${body}`;
  const sig = esKeys
    ? cryptoSign("sha256", Buffer.from(data), { key: esKeys.privateKey, dsaEncoding: "ieee-p1363" }).toString("base64url")
    : createHmac("sha256", jwtSecret).update(data).digest("base64url");
  return `${data}.${sig}`;
}

/** The payload of a valid, unexpired access token issued by this mock, or null. */
function verifyAccessToken(token) {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const header = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"));
    const data = `${parts[0]}.${parts[1]}`;
    if (esKeys) {
      if (header?.alg !== "ES256" || header?.kid !== ES_KID) return null;
      const good = cryptoVerify("sha256", Buffer.from(data), { key: esKeys.publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(parts[2], "base64url"));
      if (!good) return null;
    } else {
      if (header?.alg !== "HS256") return null;
      if (!safeEqual(parts[2], createHmac("sha256", jwtSecret).update(data).digest("base64url"))) return null;
    }
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    if (!isObject(payload) || typeof payload.exp !== "number" || payload.exp * 1000 <= now()) return null;
    if (payload.aud !== "authenticated" || payload.iss !== issuer) return null;
    return payload;
  } catch {
    return null;
  }
}

/** Builds the session JSON for `sid` and registers a fresh refresh token for it. */
function issueSession(sid, userId, email) {
  const iat = Math.floor(now() / 1000);
  const exp = iat + accessTtlSeconds;
  const accessToken = signAccessToken({
    iss: issuer,
    aud: "authenticated",
    sub: userId,
    iat,
    exp,
    email,
    phone: "",
    role: "authenticated",
    aal: "aal1",
    amr: [{ method: "otp", timestamp: iat }],
    session_id: sid,
    jti: randomUUID(), // makes two tokens issued in the same second differ
    is_anonymous: false,
    app_metadata: { provider: "email", providers: ["email"] },
    user_metadata: { email, email_verified: true, sub: userId },
  });
  const refreshToken = newRefreshToken();
  refreshTokens.set(refreshToken, { sid, used: false });
  return {
    access_token: accessToken,
    token_type: "bearer",
    expires_in: accessTtlSeconds,
    expires_at: exp,
    refresh_token: refreshToken,
    user: { id: userId, aud: "authenticated", role: "authenticated", email },
  };
}

/** Removes a session and its refresh tokens: they are then "not found", as after a real sign-out. */
function deleteSession(sid) {
  sessions.delete(sid);
  for (const [token, entry] of refreshTokens) if (entry.sid === sid) refreshTokens.delete(token);
}

/** Reuse detection: the whole session dies, and every token in it now reads as already used. */
function killSessionForReuse(sid) {
  sessions.delete(sid);
  for (const entry of refreshTokens.values()) if (entry.sid === sid) entry.used = true;
}

// ---------------------------------------------------------------------------
// Injected failures
// ---------------------------------------------------------------------------

function routeName(pathname) {
  switch (pathname) {
    case "/auth/v1/otp":
      return "otp";
    case "/auth/v1/verify":
      return "verify";
    case "/auth/v1/token":
      return "token";
    case "/auth/v1/logout":
      return "logout";
    case "/rest/v1/profiles":
      return "profiles";
    case "/rest/v1/referrals":
      return "referrals";
    default:
      return null;
  }
}

/** Consumes one use of the first rule that matches this route; returns its mode or null. */
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
      return authError(res, 503, "unexpected_failure", "mock outage");
    case "500":
      return authError(res, 500, "unexpected_failure", "mock failure");
    case "429":
      return authError(res, 429, "over_request_rate_limit", "mock rate limit", { "retry-after": "30" });
  }
}

// ---------------------------------------------------------------------------
// GoTrue routes
// ---------------------------------------------------------------------------

async function handleOtp(req, res) {
  const parsed = await readJson(req);
  if (!parsed.ok) return authError(res, parsed.tooLarge ? 413 : 400, parsed.tooLarge ? "request_entity_too_large" : "bad_json", "Could not parse request body as JSON");
  if (!isObject(parsed.value)) return authError(res, 400, "bad_json", "Could not parse request body as JSON");
  const email = normaliseEmail(parsed.value.email);
  if (!email) return authError(res, 400, "validation_failed", "Unable to validate email address: invalid format");

  const sentAt = lastSent.get(email);
  if (resendSeconds > 0 && sentAt !== undefined && now() - sentAt < resendSeconds * 1000) {
    const wait = Math.max(1, Math.ceil((sentAt + resendSeconds * 1000 - now()) / 1000));
    return authError(res, 429, "over_email_send_rate_limit", `For security purposes, you can only request this after ${wait} seconds.`, { "retry-after": String(wait) });
  }

  const code = fixedCode ?? String(randomInt(0, 1_000_000)).padStart(6, "0");
  activeCodes.set(email, { code, expiresAt: now() + otpTtlSeconds * 1000 }); // replaces any earlier code
  lastCodes.set(email, code);
  lastSent.set(email, now());
  process.stdout.write(`mock-supabase: code for ${email} is ${code}\n`);
  return send(res, 200, {});
}

async function handleVerify(req, res) {
  const parsed = await readJson(req);
  if (!parsed.ok) return authError(res, parsed.tooLarge ? 413 : 400, parsed.tooLarge ? "request_entity_too_large" : "bad_json", "Could not parse request body as JSON");
  if (!isObject(parsed.value)) return authError(res, 400, "bad_json", "Could not parse request body as JSON");
  const { type, token } = parsed.value;
  const email = normaliseEmail(parsed.value.email);
  if (type !== "email") return authError(res, 400, "validation_failed", "Only type \"email\" is supported by this mock");
  if (!email) return authError(res, 400, "validation_failed", "Unable to validate email address: invalid format");
  if (typeof token !== "string" || !/^\d{6,10}$/.test(token)) return authError(res, 422, "validation_failed", "Verify requires a 6 to 10 digit token");

  const attempts = verifyAttempts.get(email) ?? { wrong: 0, lockedUntil: 0 };
  if (attempts.lockedUntil > now()) {
    const wait = Math.max(1, Math.ceil((attempts.lockedUntil - now()) / 1000));
    return authError(res, 429, "over_request_rate_limit", "Too many verification attempts", { "retry-after": String(wait) });
  }
  if (attempts.lockedUntil !== 0) {
    attempts.wrong = 0; // lockout served
    attempts.lockedUntil = 0;
  }

  const active = activeCodes.get(email);
  // Wrong, expired, used and never-issued look identical, as in real GoTrue.
  const valid = active !== undefined && active.expiresAt > now() && safeEqual(active.code, token);
  if (!valid) {
    attempts.wrong += 1;
    if (attempts.wrong >= maxVerifyAttempts) attempts.lockedUntil = now() + lockoutSeconds * 1000;
    verifyAttempts.set(email, attempts);
    return authError(res, 403, "otp_expired", "Email link is invalid or has expired");
  }

  activeCodes.delete(email); // single use
  verifyAttempts.delete(email);
  const sid = randomUUID();
  const userId = userIdFor(email);
  sessions.set(sid, { userId, email });
  return send(res, 200, issueSession(sid, userId, email));
}

async function handleToken(req, res, url) {
  const grant = url.searchParams.get("grant_type");
  if (grant !== "refresh_token") return authError(res, 400, "validation_failed", "unsupported_grant_type: this mock only supports refresh_token");
  const parsed = await readJson(req);
  if (!parsed.ok || !isObject(parsed.value)) return authError(res, 400, "bad_json", "Could not parse request body as JSON");
  const presented = parsed.value.refresh_token;
  if (typeof presented !== "string" || presented.length === 0) return authError(res, 400, "validation_failed", "refresh_token is required");

  const entry = refreshTokens.get(presented);
  if (!entry) return authError(res, 400, "refresh_token_not_found", "Invalid Refresh Token: Refresh Token Not Found");
  if (entry.used) {
    killSessionForReuse(entry.sid);
    return authError(res, 400, "refresh_token_already_used", "Invalid Refresh Token: Already Used");
  }
  const session = sessions.get(entry.sid);
  if (!session) return authError(res, 400, "refresh_token_not_found", "Invalid Refresh Token: Refresh Token Not Found");

  entry.used = true; // rotation: the presented token is now spent
  return send(res, 200, issueSession(entry.sid, session.userId, session.email));
}

function handleLogout(req, res, url) {
  const header = req.headers["authorization"] ?? "";
  const payload = header.startsWith("Bearer ") ? verifyAccessToken(header.slice("Bearer ".length)) : null;
  if (!payload) return authError(res, 401, "bad_jwt", "invalid JWT");
  const scope = url.searchParams.get("scope") ?? "global";
  if (scope !== "local" && scope !== "global" && scope !== "others") return authError(res, 400, "validation_failed", "Unsupported logout scope");

  // Idempotent: a session that is already gone is still a 204.
  if (scope === "local") deleteSession(payload.session_id);
  else {
    for (const [sid, session] of [...sessions]) {
      if (session.userId !== payload.sub) continue;
      if (scope === "global" || sid !== payload.session_id) deleteSession(sid);
    }
  }
  return send(res, 204);
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

async function handleDev(req, res, url) {
  const notFound = () => authError(res, 404, "not_found", "not found");
  if (req.method === "GET" && url.pathname === "/__dev/last-code") {
    const email = normaliseEmail(url.searchParams.get("email"));
    const code = email ? lastCodes.get(email) : undefined;
    return code === undefined ? notFound() : send(res, 200, { code });
  }
  if (req.method !== "POST") return notFound();

  if (url.pathname === "/__dev/reset") {
    resetState();
    return send(res, 200, { ok: true });
  }
  const parsed = await readJson(req);
  if (!parsed.ok || !isObject(parsed.value)) return authError(res, 400, "bad_json", "Could not parse request body as JSON");
  const body = parsed.value;

  if (url.pathname === "/__dev/fail") {
    const routes = new Set(["otp", "verify", "token", "logout", "profiles", "referrals", "any"]);
    const modes = new Set(["503", "429", "500", "drop", "hang"]);
    const times = body.times === undefined ? 1 : body.times;
    if (!routes.has(body.route) || !modes.has(body.mode) || !Number.isInteger(times) || times < 1) {
      return authError(res, 400, "validation_failed", 'need {"route": otp|verify|token|logout|profiles|referrals|any, "mode": 503|429|500|drop|hang, "times": n>=1}');
    }
    failRules.push({ route: body.route, mode: body.mode, times });
    return send(res, 200, { ok: true });
  }
  if (url.pathname === "/__dev/set-referral-code") {
    const id = typeof body.id === "string" ? body.id.toLowerCase() : "";
    const code = typeof body.code === "string" ? body.code.toLowerCase() : "";
    if (!UUID.test(id) || code.length === 0) return authError(res, 400, "validation_failed", "need {\"id\": <uuid>, \"code\": <non-empty string>}");
    referralCodes.set(code, id);
    return send(res, 200, { ok: true });
  }
  if (url.pathname === "/__dev/revoke") {
    const email = normaliseEmail(body.email);
    if (!email) return authError(res, 400, "validation_failed", "email is required");
    const userId = userIdFor(email);
    let revoked = 0;
    for (const [sid, session] of [...sessions]) {
      if (session.userId === userId) {
        deleteSession(sid);
        revoked += 1;
      }
    }
    return send(res, 200, { revoked });
  }
  return notFound();
}

// ---------------------------------------------------------------------------
// PostgREST profiles (unchanged behaviour)
// ---------------------------------------------------------------------------

// Returns the uuid from an `id=eq.<uuid>` filter, or null if absent/invalid.
function userIdFilter(params) {
  const value = params.get("id") ?? "";
  if (!value.startsWith("eq.")) return null;
  const id = value.slice(3);
  return UUID.test(id) ? id.toLowerCase() : null;
}

// Returns the code from a `referral_code=eq.<code>` filter, or null if absent.
function referralCodeFilter(params) {
  const value = params.get("referral_code") ?? "";
  if (!value.startsWith("eq.")) return null;
  return decodeURIComponent(value.slice(3)).toLowerCase();
}

async function handleProfiles(req, res, url) {
  if (!req.headers["apikey"] || !req.headers["authorization"]) return send(res, 401, NO_API_KEY);

  // referral.ts looks a referrer up by their referral_code (GET-only; a real profile row is
  // never created by this mock, so there is nothing to PATCH through this filter).
  const code = referralCodeFilter(url.searchParams);
  if (code !== null) {
    if (req.method !== "GET") return send(res, 405, { message: "method not allowed" });
    const id = referralCodes.get(code);
    return send(res, 200, id ? [{ id }] : []);
  }

  const id = userIdFilter(url.searchParams);
  if (!id) return send(res, 400, { message: 'expected an `id=eq.<uuid>` or `referral_code=eq.<code>` filter' });

  if (req.method === "GET") return send(res, 200, [{ tier: tiers.get(id) ?? defaultTier }]);

  if (req.method === "PATCH") {
    const parsed = await readJson(req);
    if (!parsed.ok) return send(res, 400, { message: "invalid JSON body" });
    const body = parsed.value;
    if (!body || typeof body !== "object" || !TIERS.has(body.tier)) return send(res, 400, { message: 'body must be {"tier":"free"|"pro"}' });
    tiers.set(id, body.tier);
    // PostgREST answers 204 for Prefer: return=minimal (what the Worker sends).
    if (String(req.headers["prefer"] ?? "").includes("return=minimal")) return send(res, 204);
    return send(res, 200, [{ id, tier: body.tier }]);
  }

  return send(res, 405, { message: "method not allowed" });
}

// Returns the uuid from a `referee_id=eq.<uuid>` filter, or null if absent/invalid.
function refereeIdFilter(params) {
  const value = params.get("referee_id") ?? "";
  if (!value.startsWith("eq.")) return null;
  const id = value.slice(3);
  return UUID.test(id) ? id.toLowerCase() : null;
}

/**
 * PostgREST /rest/v1/referrals, the two calls referral.ts makes: GET to check whether the
 * referee already redeemed, POST to record a redemption pair. The table's real constraints
 * (0002_referrals.sql: no_self_referral, unique_referee) are mirrored here as best-effort
 * checks so the mock rejects the same shapes the real database would (23514 / 23505), but this
 * is not a substitute for backend/supabase/scripts/check-migration.mjs, which checks the actual
 * constraints against Postgres.
 */
async function handleReferrals(req, res, url) {
  if (!req.headers["apikey"] || !req.headers["authorization"]) return send(res, 401, NO_API_KEY);

  if (req.method === "GET") {
    const refereeId = refereeIdFilter(url.searchParams);
    if (!refereeId) return send(res, 400, { message: "expected a `referee_id=eq.<uuid>` filter" });
    const matches = referrals.filter((r) => r.referee_id === refereeId).map((r) => ({ id: r.id }));
    return send(res, 200, matches);
  }

  if (req.method === "POST") {
    const parsed = await readJson(req);
    if (!parsed.ok) return send(res, 400, { message: "invalid JSON body" });
    const body = parsed.value;
    if (!isObject(body) || typeof body.referrer_id !== "string" || typeof body.referee_id !== "string" || typeof body.code !== "string") {
      return send(res, 400, { message: 'body must be {"referrer_id","referee_id","code"}' });
    }
    const referrerId = body.referrer_id.toLowerCase();
    const refereeId = body.referee_id.toLowerCase();
    if (!UUID.test(referrerId) || !UUID.test(refereeId)) return send(res, 400, { message: "referrer_id and referee_id must be uuids" });
    if (referrerId === refereeId) {
      return send(res, 400, { message: 'new row for relation "referrals" violates check constraint "no_self_referral"', code: "23514" });
    }
    if (referrals.some((r) => r.referee_id === refereeId)) {
      return send(res, 409, { message: 'duplicate key value violates unique constraint "unique_referee"', code: "23505" });
    }
    const row = { id: randomUUID(), referrer_id: referrerId, referee_id: refereeId, code: body.code };
    referrals.push(row);
    // PostgREST answers 201 for an insert; the body depends on Prefer, same as the profiles PATCH above.
    if (String(req.headers["prefer"] ?? "").includes("return=minimal")) return send(res, 201);
    return send(res, 201, [row]);
  }

  return send(res, 405, { message: "method not allowed" });
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const AUTH_ROUTES = {
  "/auth/v1/otp": { method: "POST", handler: handleOtp },
  "/auth/v1/verify": { method: "POST", handler: handleVerify },
  "/auth/v1/token": { method: "POST", handler: handleToken },
  "/auth/v1/logout": { method: "POST", handler: handleLogout },
};

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://127.0.0.1");
  // Log method and route only: no query string, headers or bodies.
  process.stdout.write(`${req.method} ${url.pathname}\n`);

  if (url.pathname.startsWith("/__dev/")) {
    // A browser page on another origin (DNS rebinding) sends its own Host: refuse it.
    if (!LOOPBACK_HOSTNAMES.has(hostnameOf(req.headers["host"]))) return authError(res, 404, "not_found", "not found");
    return handleDev(req, res, url);
  }

  if (failMode === "drop") return req.socket.destroy();
  if (failMode === "503") return send(res, 503, { message: "mock outage" });

  const injected = takeInjectedFailure(routeName(url.pathname));
  if (injected) return applyFailure(injected, req, res);

  if (url.pathname === "/auth/v1/.well-known/jwks.json") {
    // Public, like the real endpoint: no apikey needed.
    if (req.method !== "GET") return authError(res, 405, "method_not_allowed", "method not allowed");
    return send(res, 200, jwks, { "cache-control": "public, max-age=600" });
  }

  const authRoute = AUTH_ROUTES[url.pathname];
  if (authRoute) {
    if (!req.headers["apikey"]) return send(res, 401, NO_API_KEY);
    if (req.method !== authRoute.method) return authError(res, 405, "method_not_allowed", "method not allowed");
    return authRoute.handler(req, res, url);
  }

  if (url.pathname === "/rest/v1/profiles") return handleProfiles(req, res, url);
  if (url.pathname === "/rest/v1/referrals") return handleReferrals(req, res, url);
  return send(res, 404, { message: "not found" });
});

server.listen(port, "127.0.0.1", () => {
  const actual = server.address().port;
  process.stdout.write(
    `mock-supabase listening on http://127.0.0.1:${actual} (default tier: ${defaultTier}, issuer: ${issuer}, jwt: ${jwtMode}${failMode ? `, MOCK_FAIL=${failMode}` : ""})\n`
  );
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    server.closeAllConnections(); // ends any connection held open by a "hang" failure
  });
}
