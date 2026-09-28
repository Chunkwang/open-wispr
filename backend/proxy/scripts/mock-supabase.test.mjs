// Contract tests for scripts/mock-supabase.mjs (docs/auth-design.md section 2).
// Run: npm run test:mock  (node's built-in runner; no dependencies beyond `jose`).
// Each test group starts the real script as a child process on port 0 with its own
// environment, so the MOCK_* knobs are tested exactly as a developer would use them.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { request as httpRequest } from "node:http";
import { dirname, join } from "node:path";
import { after, before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { SignJWT, createLocalJWKSet, decodeProtectedHeader, jwtVerify } from "jose";

const MOCK = join(dirname(fileURLToPath(import.meta.url)), "mock-supabase.mjs");
const SECRET = "local-dev-mock-test-secret-0123456789";
const SUPABASE_URL = "https://test-project.supabase.test";
const ISSUER = `${SUPABASE_URL}/auth/v1`;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Starts the mock on a free port. `env` values of undefined are removed from the child's environment. */
async function startMock(env = {}) {
  const childEnv = { ...process.env, PORT: "0", SUPABASE_URL, SUPABASE_JWT_SECRET: SECRET, ...env };
  for (const key of Object.keys(childEnv)) {
    if (childEnv[key] === undefined || (key.startsWith("MOCK_") && !(key in env))) delete childEnv[key];
  }
  const child = spawn(process.execPath, [MOCK], { env: childEnv, stdio: ["ignore", "pipe", "pipe"] });
  let out = "";
  let err = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (err += d));
  const port = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`mock did not start: ${out}${err}`)), 5000);
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`mock exited early (${code}): ${err}`));
    });
    child.stdout.on("data", () => {
      const match = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
      if (match) {
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    });
  });
  const base = `http://127.0.0.1:${port}`;
  let counter = 0;
  const mock = {
    port,
    base,
    stdout: () => out,
    stderr: () => err,
    /** A fresh address, so tests never trip each other's resend limit. */
    email: () => `user${++counter}-${Math.random().toString(36).slice(2, 8)}@example.com`,
    async call(method, path, { body, headers = {}, apikey = true, signal } = {}) {
      const h = { ...headers };
      if (apikey) h.apikey = "anon-key-for-tests";
      let payload;
      if (body !== undefined) {
        payload = typeof body === "string" ? body : JSON.stringify(body);
        h["content-type"] = "application/json";
      }
      const res = await fetch(base + path, { method, headers: h, body: payload, signal });
      const text = await res.text();
      let json;
      try {
        json = text ? JSON.parse(text) : undefined;
      } catch {
        json = undefined;
      }
      return { status: res.status, headers: res.headers, text, json };
    },
    otp: (email) => mock.call("POST", "/auth/v1/otp", { body: { email, create_user: true } }),
    verify: (email, token) => mock.call("POST", "/auth/v1/verify", { body: { type: "email", email, token } }),
    refresh: (refresh_token) => mock.call("POST", "/auth/v1/token?grant_type=refresh_token", { body: { refresh_token } }),
    logout: (access, scope = "local") =>
      mock.call("POST", `/auth/v1/logout?scope=${scope}`, { headers: access ? { authorization: `Bearer ${access}` } : {} }),
    lastCode: async (email) => {
      const res = await mock.call("GET", `/__dev/last-code?email=${encodeURIComponent(email)}`, { apikey: false });
      return res.status === 200 ? res.json.code : undefined;
    },
    dev: (path, body) => mock.call("POST", path, { body, apikey: false }),
    async signIn(email = mock.email()) {
      assert.equal((await mock.otp(email)).status, 200);
      const res = await mock.verify(email, await mock.lastCode(email));
      assert.equal(res.status, 200, res.text);
      return { email, ...res.json };
    },
    async stop() {
      if (child.exitCode !== null) return;
      const exited = new Promise((resolve) => child.on("exit", resolve));
      child.kill("SIGTERM");
      await exited;
    },
  };
  return mock;
}

/** Same options as src/auth.ts, plus its UUID subject check. */
async function verifyLikeTheWorker(token, { secret = SECRET, issuer = ISSUER } = {}) {
  const { payload } = await jwtVerify(token, new TextEncoder().encode(secret), {
    algorithms: ["HS256"],
    audience: "authenticated",
    issuer,
    requiredClaims: ["exp", "sub"],
  });
  assert.match(payload.sub, UUID);
  return payload;
}

/** GET with an arbitrary Host header (fetch cannot set one). */
function getWithHost(port, path, host) {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port, path, method: "GET", headers: { host } }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode, text }));
    });
    req.on("error", reject);
    req.end();
  });
}

const OTP_ERROR = { code: 403, error_code: "otp_expired", msg: "Email link is invalid or has expired" };

describe("startup", () => {
  it("prints the actual port and the issuer, and PORT=0 works", async () => {
    const mock = await startMock();
    try {
      assert.match(mock.stdout(), /listening on http:\/\/127\.0\.0\.1:\d+ .*issuer: https:\/\/test-project\.supabase\.test\/auth\/v1/);
    } finally {
      await mock.stop();
    }
  });

  async function exitsWith(env, pattern) {
    const child = spawn(process.execPath, [MOCK], { env: { ...process.env, PORT: "0", ...env }, stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    child.stderr.on("data", (d) => (err += d));
    // A mock that fails to refuse must not hang the suite or be left running.
    const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
    const code = await new Promise((resolve) => child.on("exit", resolve));
    clearTimeout(timer);
    assert.equal(typeof code, "number", "the mock kept running instead of exiting");
    assert.notEqual(code, 0);
    assert.match(err, pattern);
  }

  it("refuses a signing secret that does not start with local-dev-", async () => {
    await exitsWith({ SUPABASE_JWT_SECRET: "a-real-looking-project-secret-0123456789" }, /local-dev-/);
  });

  it("refuses a bad MOCK_FIXED_CODE and a bad numeric knob", async () => {
    await exitsWith({ SUPABASE_JWT_SECRET: SECRET, MOCK_FIXED_CODE: "12ab56" }, /MOCK_FIXED_CODE/);
    await exitsWith({ SUPABASE_JWT_SECRET: SECRET, MOCK_OTP_TTL_SECONDS: "0" }, /MOCK_OTP_TTL_SECONDS/);
  });
});

describe("POST /auth/v1/otp", () => {
  let mock;
  before(async () => (mock = await startMock()));
  after(() => mock.stop());

  it("answers 200 {} and prints the code line", async () => {
    const email = mock.email();
    const res = await mock.otp(email);
    assert.equal(res.status, 200);
    assert.deepEqual(res.json, {});
    const code = await mock.lastCode(email);
    assert.match(code, /^\d{6}$/);
    assert.ok(mock.stdout().includes(`mock-supabase: code for ${email} is ${code}`));
  });

  it("rejects an invalid email with 400 validation_failed (GoTrue error shape)", async () => {
    for (const email of ["", "nobody", "a@b", "two words@example.com", 42, null]) {
      const res = await mock.otp(email);
      assert.equal(res.status, 400, JSON.stringify(email));
      assert.equal(res.json.error_code, "validation_failed");
      assert.equal(res.json.code, 400);
      assert.equal(typeof res.json.msg, "string");
    }
    assert.equal((await mock.call("POST", "/auth/v1/otp", { body: "not json" })).status, 400);
  });

  it("requires the apikey header", async () => {
    const res = await mock.call("POST", "/auth/v1/otp", { body: { email: mock.email() }, apikey: false });
    assert.equal(res.status, 401);
    assert.equal(res.json.message, "No API key found in request");
  });

  it("limits a second send within the resend window: 429 over_email_send_rate_limit with Retry-After", async () => {
    const email = mock.email();
    assert.equal((await mock.otp(email)).status, 200);
    const res = await mock.otp(email);
    assert.equal(res.status, 429);
    assert.equal(res.json.error_code, "over_email_send_rate_limit");
    const wait = Number(res.headers.get("retry-after"));
    assert.ok(wait >= 1 && wait <= 60, `retry-after ${wait}`);
    // Another address is unaffected, and the address is case-insensitive.
    assert.equal((await mock.otp(mock.email())).status, 200);
    assert.equal((await mock.otp(email.toUpperCase())).status, 429);
  });

  it("does not put the query string, the email or a token in the request log lines", async () => {
    const email = mock.email();
    await mock.otp(email);
    await mock.lastCode(email);
    const lines = mock.stdout().split("\n").filter((l) => !l.startsWith("mock-supabase:"));
    assert.ok(lines.some((l) => l === "GET /__dev/last-code"));
    assert.ok(!lines.some((l) => l.includes("?") || l.includes("@")));
  });
});

describe("POST /auth/v1/verify", () => {
  let mock;
  before(async () => (mock = await startMock({ MOCK_OTP_RESEND_SECONDS: "0" })));
  after(() => mock.stop());

  it("returns a session with the documented shape", async () => {
    const email = mock.email();
    await mock.otp(email);
    const res = await mock.verify(email, await mock.lastCode(email));
    assert.equal(res.status, 200);
    const s = res.json;
    assert.equal(s.token_type, "bearer");
    assert.equal(s.expires_in, 3600);
    assert.ok(Math.abs(s.expires_at - (Math.floor(Date.now() / 1000) + 3600)) <= 5);
    assert.match(s.refresh_token, /^[A-Za-z0-9_-]{12}$/);
    assert.deepEqual(s.user, { id: s.user.id, aud: "authenticated", role: "authenticated", email });
    assert.match(s.user.id, UUID);
  });

  it("issues an HS256 access token the Worker's verification accepts (jose, same options as auth.ts)", async () => {
    const s = await mock.signIn();
    const payload = await verifyLikeTheWorker(s.access_token);
    assert.equal(payload.sub, s.user.id);
    assert.equal(payload.aud, "authenticated");
    assert.equal(payload.iss, ISSUER);
    assert.equal(payload.role, "authenticated");
    assert.equal(payload.email, s.email);
    assert.match(payload.session_id, UUID);
    assert.equal(payload.exp, s.expires_at);
    assert.ok(payload.iat <= payload.exp && typeof payload.iat === "number");
    assert.equal(payload.app_metadata.provider, "email");
    assert.ok("user_metadata" in payload);
    // And it is only valid for that secret and issuer.
    await assert.rejects(verifyLikeTheWorker(s.access_token, { secret: "local-dev-a-different-secret-0123456789" }));
    await assert.rejects(verifyLikeTheWorker(s.access_token, { issuer: "https://other.supabase.test/auth/v1" }));
  });

  it("derives the user id as UUID v5 of the lowercased email (stable across sign-ins and case)", async () => {
    // uuid5(NAMESPACE_DNS, "alice@example.com"), computed independently with Python's uuid module.
    const expected = "edabafbb-61ad-51d6-9fd8-e976c892a731";
    const first = await mock.signIn("alice@example.com");
    assert.equal(first.user.id, expected);
    const second = await mock.signIn("  Alice@Example.COM ");
    assert.equal(second.user.id, expected);
    assert.equal(second.user.email, "alice@example.com");
    assert.notEqual((await mock.signIn()).user.id, expected);
  });

  it("rejects a wrong code with 403 otp_expired, and a code is single use", async () => {
    const email = mock.email();
    await mock.otp(email);
    const code = await mock.lastCode(email);
    const wrong = code === "000000" ? "111111" : "000000";
    const bad = await mock.verify(email, wrong);
    assert.equal(bad.status, 403);
    assert.deepEqual(bad.json, OTP_ERROR);
    assert.equal((await mock.verify(email, code)).status, 200);
    const again = await mock.verify(email, code);
    assert.equal(again.status, 403);
    assert.deepEqual(again.json, OTP_ERROR);
  });

  it("does not tell wrong, used and unknown-email apart (identical status and body)", async () => {
    const email = mock.email();
    await mock.otp(email);
    const code = await mock.lastCode(email);
    const wrongBody = (await mock.verify(email, code === "999999" ? "888888" : "999999")).text;
    const unknownBody = (await mock.verify(mock.email(), "123456")).text;
    await mock.verify(email, code);
    const usedBody = (await mock.verify(email, code)).text;
    assert.equal(wrongBody, unknownBody);
    assert.equal(wrongBody, usedBody);
  });

  it("a new code replaces the old one", async () => {
    const email = mock.email();
    await mock.otp(email);
    const first = await mock.lastCode(email);
    await mock.otp(email);
    const second = await mock.lastCode(email);
    if (first !== second) assert.equal((await mock.verify(email, first)).status, 403);
    assert.equal((await mock.verify(email, second)).status, 200);
  });

  it("validates the request: type must be email, token 6 to 10 digits, email valid", async () => {
    const email = mock.email();
    const cases = [
      [{ type: "magiclink", email, token: "123456" }, 400],
      [{ type: "email", email: "nope", token: "123456" }, 400],
      [{ type: "email", email }, 422],
      [{ type: "email", email, token: "12ab56" }, 422],
      [{ type: "email", email, token: "12345" }, 422],
      [{ type: "email", email, token: "12345678901" }, 422],
      [{ type: "email", email, token: 123456 }, 422],
    ];
    for (const [body, status] of cases) {
      const res = await mock.call("POST", "/auth/v1/verify", { body });
      assert.equal(res.status, status, JSON.stringify(body));
      assert.equal(res.json.error_code, "validation_failed");
    }
    assert.equal((await mock.call("POST", "/auth/v1/verify", { body: "[]" })).status, 400);
  });

  it("requires the apikey header and the POST method", async () => {
    assert.equal((await mock.call("POST", "/auth/v1/verify", { body: {}, apikey: false })).status, 401);
    assert.equal((await mock.call("GET", "/auth/v1/verify")).status, 405);
  });
});

describe("verify: expiry, lockout and knobs", () => {
  it("a code older than MOCK_OTP_TTL_SECONDS is rejected like a wrong one", async () => {
    const mock = await startMock({ MOCK_OTP_TTL_SECONDS: "1" });
    try {
      const email = mock.email();
      await mock.otp(email);
      const code = await mock.lastCode(email);
      await sleep(1200);
      const res = await mock.verify(email, code);
      assert.equal(res.status, 403);
      assert.deepEqual(res.json, OTP_ERROR);
    } finally {
      await mock.stop();
    }
  });

  it("MOCK_MAX_VERIFY_ATTEMPTS wrong tries lock the email out: 429 over_request_rate_limit, even for the right code", async () => {
    const mock = await startMock({ MOCK_MAX_VERIFY_ATTEMPTS: "3", MOCK_FIXED_CODE: "424242" });
    try {
      const email = mock.email();
      await mock.otp(email);
      for (let i = 0; i < 3; i++) assert.equal((await mock.verify(email, "000000")).status, 403);
      const locked = await mock.verify(email, "000000");
      assert.equal(locked.status, 429);
      assert.equal(locked.json.error_code, "over_request_rate_limit");
      assert.ok(Number(locked.headers.get("retry-after")) >= 1);
      const right = await mock.verify(email, "424242");
      assert.equal(right.status, 429, "the correct code is refused while locked out");
      // Another email is not affected.
      const other = mock.email();
      await mock.otp(other);
      assert.equal((await mock.verify(other, "424242")).status, 200);
    } finally {
      await mock.stop();
    }
  });

  it("the lockout ends after MOCK_LOCKOUT_SECONDS and the counter restarts", async () => {
    const mock = await startMock({ MOCK_MAX_VERIFY_ATTEMPTS: "2", MOCK_LOCKOUT_SECONDS: "1", MOCK_FIXED_CODE: "424242" });
    try {
      const email = mock.email();
      await mock.otp(email);
      await mock.verify(email, "000000");
      await mock.verify(email, "000000");
      assert.equal((await mock.verify(email, "424242")).status, 429);
      await sleep(1200);
      assert.equal((await mock.verify(email, "424242")).status, 200);
    } finally {
      await mock.stop();
    }
  });

  it("MOCK_FIXED_CODE is used for every code; MOCK_OTP_RESEND_SECONDS=0 removes the limit", async () => {
    const mock = await startMock({ MOCK_FIXED_CODE: "12345678", MOCK_OTP_RESEND_SECONDS: "0" });
    try {
      const email = mock.email();
      assert.equal((await mock.otp(email)).status, 200);
      assert.equal((await mock.otp(email)).status, 200);
      assert.equal(await mock.lastCode(email), "12345678");
      assert.equal((await mock.verify(email, "12345678")).status, 200);
    } finally {
      await mock.stop();
    }
  });

  it("MOCK_OTP_RESEND_SECONDS sets the Retry-After window", async () => {
    const mock = await startMock({ MOCK_OTP_RESEND_SECONDS: "5" });
    try {
      const email = mock.email();
      await mock.otp(email);
      const res = await mock.otp(email);
      assert.equal(res.status, 429);
      const wait = Number(res.headers.get("retry-after"));
      assert.ok(wait >= 1 && wait <= 5, `retry-after ${wait}`);
    } finally {
      await mock.stop();
    }
  });

  it("MOCK_ACCESS_TTL_SECONDS sets expires_in and the token really expires", async () => {
    const mock = await startMock({ MOCK_ACCESS_TTL_SECONDS: "1" });
    try {
      const s = await mock.signIn();
      assert.equal(s.expires_in, 1);
      const payload = await verifyLikeTheWorker(s.access_token).catch(() => null);
      // Either still valid this instant or already expired; after 2 s it must be expired.
      if (payload) assert.equal(payload.exp - payload.iat, 1);
      await sleep(2100);
      await assert.rejects(verifyLikeTheWorker(s.access_token));
    } finally {
      await mock.stop();
    }
  });
});

describe("POST /auth/v1/token?grant_type=refresh_token", () => {
  let mock;
  before(async () => (mock = await startMock({ MOCK_OTP_RESEND_SECONDS: "0" })));
  after(() => mock.stop());

  it("rotates: a new refresh token and a new access token for the same user and session", async () => {
    const s = await mock.signIn();
    const res = await mock.refresh(s.refresh_token);
    assert.equal(res.status, 200);
    assert.notEqual(res.json.refresh_token, s.refresh_token);
    assert.match(res.json.refresh_token, /^[A-Za-z0-9_-]{12}$/);
    assert.notEqual(res.json.access_token, s.access_token);
    assert.equal(res.json.user.id, s.user.id);
    const before = await verifyLikeTheWorker(s.access_token);
    const after = await verifyLikeTheWorker(res.json.access_token);
    assert.equal(after.session_id, before.session_id);
    assert.equal(after.sub, before.sub);
    // The new token rotates again.
    assert.equal((await mock.refresh(res.json.refresh_token)).status, 200);
  });

  it("detects reuse: the rotated-out token gets refresh_token_already_used and the whole session dies", async () => {
    const s = await mock.signIn();
    const rotated = (await mock.refresh(s.refresh_token)).json;
    const reuse = await mock.refresh(s.refresh_token);
    assert.equal(reuse.status, 400);
    assert.equal(reuse.json.error_code, "refresh_token_already_used");
    assert.equal(reuse.json.code, 400);
    // The newest token of that session is dead too.
    const dead = await mock.refresh(rotated.refresh_token);
    assert.equal(dead.status, 400);
    assert.match(dead.json.error_code, /^(refresh_token_already_used|refresh_token_not_found|session_not_found)$/);
  });

  it("answers refresh_token_not_found for an unknown token", async () => {
    const res = await mock.refresh("AAAAAAAAAAAA");
    assert.equal(res.status, 400);
    assert.equal(res.json.error_code, "refresh_token_not_found");
  });

  it("validates the request", async () => {
    assert.equal((await mock.call("POST", "/auth/v1/token?grant_type=refresh_token", { body: {} })).status, 400);
    assert.equal((await mock.call("POST", "/auth/v1/token?grant_type=refresh_token", { body: { refresh_token: "" } })).status, 400);
    assert.equal((await mock.call("POST", "/auth/v1/token?grant_type=refresh_token", { body: "nope" })).status, 400);
    const other = await mock.call("POST", "/auth/v1/token?grant_type=password", { body: { email: "a@b.co", password: "x" } });
    assert.equal(other.status, 400);
    assert.equal(other.json.error_code, "validation_failed");
    assert.equal((await mock.call("POST", "/auth/v1/token", { body: {} })).status, 400);
    assert.equal((await mock.call("POST", "/auth/v1/token?grant_type=refresh_token", { body: { refresh_token: "x" }, apikey: false })).status, 401);
  });

  it("concurrent refreshes of one token: exactly one wins (client must single-flight)", async () => {
    const s = await mock.signIn();
    const results = await Promise.all([mock.refresh(s.refresh_token), mock.refresh(s.refresh_token), mock.refresh(s.refresh_token)]);
    assert.equal(results.filter((r) => r.status === 200).length, 1);
  });
});

describe("POST /auth/v1/logout", () => {
  let mock;
  before(async () => (mock = await startMock({ MOCK_OTP_RESEND_SECONDS: "0" })));
  after(() => mock.stop());

  it("scope=local answers 204 and revokes that session's refresh tokens", async () => {
    const s = await mock.signIn();
    const res = await mock.logout(s.access_token, "local");
    assert.equal(res.status, 204);
    assert.equal(res.text, "");
    const refreshed = await mock.refresh(s.refresh_token);
    assert.equal(refreshed.status, 400);
    assert.equal(refreshed.json.error_code, "refresh_token_not_found");
  });

  it("is idempotent for a session that is already gone", async () => {
    const s = await mock.signIn();
    assert.equal((await mock.logout(s.access_token)).status, 204);
    assert.equal((await mock.logout(s.access_token)).status, 204);
  });

  it("rejects a missing, malformed, wrongly signed, expired or foreign-issuer token with 401 bad_jwt", async () => {
    const good = (await mock.signIn()).access_token;
    const now = Math.floor(Date.now() / 1000);
    const forge = (claims, secret = SECRET) =>
      new SignJWT({ role: "authenticated", session_id: crypto.randomUUID(), ...claims })
        .setProtectedHeader({ alg: "HS256" })
        .setSubject(crypto.randomUUID())
        .sign(new TextEncoder().encode(secret));
    const tokens = [
      null,
      "garbage",
      good.slice(0, -2) + (good.endsWith("AA") ? "BB" : "AA"),
      await forge({ aud: "authenticated", iss: ISSUER, exp: now + 60 }, "local-dev-not-the-mock-secret-0123456789"),
      await forge({ aud: "authenticated", iss: ISSUER, exp: now - 60 }),
      await forge({ aud: "authenticated", iss: "https://other.supabase.test/auth/v1", exp: now + 60 }),
      await forge({ aud: "anon", iss: ISSUER, exp: now + 60 }),
    ];
    for (const token of tokens) {
      const res = await mock.logout(token);
      assert.equal(res.status, 401, String(token).slice(0, 20));
      assert.equal(res.json.error_code, "bad_jwt");
    }
    const noHeader = await mock.call("POST", "/auth/v1/logout?scope=local");
    assert.equal(noHeader.status, 401);
    assert.equal((await mock.call("POST", "/auth/v1/logout", { headers: { authorization: `Bearer ${good}` }, apikey: false })).status, 401);
  });

  it("scope=others keeps this session, scope=global ends all of them, an unknown scope is 400", async () => {
    const email = mock.email();
    const a = await mock.signIn(email);
    const b = await mock.signIn(email);
    assert.equal((await mock.logout(a.access_token, "others")).status, 204);
    assert.equal((await mock.refresh(b.refresh_token)).status, 400, "b was the other session");
    const c = await mock.refresh(a.refresh_token);
    assert.equal(c.status, 200, "a is the current session and survives");
    assert.equal((await mock.logout(c.json.access_token, "global")).status, 204);
    assert.equal((await mock.refresh(c.json.refresh_token)).status, 400);
    assert.equal((await mock.logout(c.json.access_token, "sideways")).status, 400);
  });
});

describe("dev-only routes", () => {
  let mock;
  before(async () => (mock = await startMock({ MOCK_OTP_RESEND_SECONDS: "0" })));
  after(() => mock.stop());

  it("last-code: the latest code, still available after use; 404 for an unknown email or a bad query", async () => {
    const email = mock.email();
    await mock.otp(email);
    const code = await mock.lastCode(email);
    assert.match(code, /^\d{6}$/);
    await mock.verify(email, code);
    assert.equal(await mock.lastCode(email), code);
    assert.equal((await mock.call("GET", `/__dev/last-code?email=${mock.email()}`, { apikey: false })).status, 404);
    assert.equal((await mock.call("GET", "/__dev/last-code", { apikey: false })).status, 404);
  });

  it("answers only to a loopback Host: every /__dev route is 404 for any other Host", async () => {
    const email = mock.email();
    await mock.otp(email);
    for (const host of ["evil.example.com", "evil.example.com:80", "127.0.0.2", "0.0.0.0", "localhost.", "[::1]"]) {
      const res = await getWithHost(mock.port, `/__dev/last-code?email=${encodeURIComponent(email)}`, host);
      assert.equal(res.status, 404, `host "${host}"`);
      assert.ok(!res.text.includes(await mock.lastCode(email)));
    }
    // Same for the POST routes (spoofed Host with a body).
    for (const path of ["/__dev/reset", "/__dev/fail", "/__dev/revoke"]) {
      const status = await new Promise((resolve, reject) => {
        const req = httpRequest({ host: "127.0.0.1", port: mock.port, path, method: "POST", headers: { host: "evil.example.com", "content-type": "application/json" } }, (res) => {
          res.resume();
          res.on("end", () => resolve(res.statusCode));
        });
        req.on("error", reject);
        req.end("{}");
      });
      assert.equal(status, 404, path);
    }
    // ...and the spoofed reset did not reset anything.
    assert.match(await mock.lastCode(email), /^\d{6}$/);
    // localhost is a loopback Host too.
    const viaLocalhost = await getWithHost(mock.port, `/__dev/last-code?email=${encodeURIComponent(email)}`, `localhost:${mock.port}`);
    assert.equal(viaLocalhost.status, 200);
  });

  it("fail: 503, 500 and 429 answer for `times` requests on that route, then the route recovers", async () => {
    for (const [mode, status, errorCode] of [
      ["503", 503, "unexpected_failure"],
      ["500", 500, "unexpected_failure"],
      ["429", 429, "over_request_rate_limit"],
    ]) {
      assert.equal((await mock.dev("/__dev/fail", { route: "otp", mode, times: 2 })).status, 200);
      const email = mock.email();
      for (let i = 0; i < 2; i++) {
        const res = await mock.otp(email);
        assert.equal(res.status, status, mode);
        assert.equal(res.json.error_code, errorCode);
        if (mode === "429") assert.ok(Number(res.headers.get("retry-after")) > 0);
      }
      assert.equal((await mock.otp(email)).status, 200, `${mode}: recovered`);
    }
  });

  it("fail: is scoped to its route; `any` covers every route; times defaults to 1", async () => {
    await mock.dev("/__dev/fail", { route: "verify", mode: "503" });
    const s = await mock.signIn().catch((e) => e); // verify fails once inside signIn
    assert.ok(s instanceof Error, "the injected verify failure fired");
    const email = mock.email();
    assert.equal((await mock.otp(email)).status, 200, "otp is not affected by a verify rule");
    assert.equal((await mock.verify(email, await mock.lastCode(email))).status, 200, "the rule was used up");

    await mock.dev("/__dev/fail", { route: "any", mode: "503", times: 2 });
    assert.equal((await mock.otp(mock.email())).status, 503);
    assert.equal((await mock.refresh("AAAAAAAAAAAA")).status, 503);
    assert.equal((await mock.refresh("AAAAAAAAAAAA")).status, 400);
  });

  it("fail: `profiles` covers the PostgREST route", async () => {
    await mock.dev("/__dev/fail", { route: "profiles", mode: "503" });
    const id = crypto.randomUUID();
    const path = `/rest/v1/profiles?id=eq.${id}&select=tier`;
    const headers = { authorization: "Bearer x" };
    assert.equal((await mock.call("GET", path, { headers })).status, 503);
    assert.equal((await mock.call("GET", path, { headers })).status, 200);
  });

  it("fail: `drop` closes the connection and `hang` never answers", async () => {
    await mock.dev("/__dev/fail", { route: "otp", mode: "drop" });
    await assert.rejects(mock.otp(mock.email()));
    await mock.dev("/__dev/fail", { route: "otp", mode: "hang" });
    await assert.rejects(mock.call("POST", "/auth/v1/otp", { body: { email: mock.email() }, signal: AbortSignal.timeout(400) }));
    assert.equal((await mock.otp(mock.email())).status, 200, "both recovered");
  });

  it("fail: rejects a bad route, mode or times with 400", async () => {
    for (const body of [{}, { route: "nope", mode: "503" }, { route: "otp", mode: "418" }, { route: "otp", mode: "503", times: 0 }, { route: "otp", mode: "503", times: 1.5 }]) {
      assert.equal((await mock.dev("/__dev/fail", body)).status, 400, JSON.stringify(body));
    }
    assert.equal((await mock.call("POST", "/__dev/fail", { body: "nope", apikey: false })).status, 400);
  });

  it("revoke: kills the user's refresh tokens, but access tokens live until exp", async () => {
    const s = await mock.signIn();
    const res = await mock.dev("/__dev/revoke", { email: s.email });
    assert.equal(res.status, 200);
    assert.equal(res.json.revoked, 1);
    const refreshed = await mock.refresh(s.refresh_token);
    assert.equal(refreshed.status, 400);
    assert.equal(refreshed.json.error_code, "refresh_token_not_found");
    await verifyLikeTheWorker(s.access_token); // still verifies
    assert.equal((await mock.dev("/__dev/revoke", { email: "not-an-email" })).status, 400);
  });

  it("reset: forgets codes, sessions, tokens, tiers, rate limits and failure rules", async () => {
    const s = await mock.signIn();
    const id = s.user.id;
    await mock.call("PATCH", `/rest/v1/profiles?id=eq.${id}`, { body: { tier: "free" }, headers: { authorization: "Bearer x" } });
    await mock.dev("/__dev/fail", { route: "otp", mode: "503", times: 5 });
    assert.equal((await mock.dev("/__dev/reset")).status, 200);
    assert.equal(await mock.lastCode(s.email), undefined);
    assert.equal((await mock.refresh(s.refresh_token)).json.error_code, "refresh_token_not_found");
    assert.equal((await mock.otp(s.email)).status, 200, "the failure rule is gone");
    const tier = await mock.call("GET", `/rest/v1/profiles?id=eq.${id}&select=tier`, { headers: { authorization: "Bearer x" } });
    assert.deepEqual(tier.json, [{ tier: "pro" }]);
  });

  it("unknown /__dev routes and methods are 404", async () => {
    assert.equal((await mock.dev("/__dev/nope", {})).status, 404);
    assert.equal((await mock.call("GET", "/__dev/reset", { apikey: false })).status, 404);
  });
});

describe("resend limit and reset together", () => {
  it("the default 60 s resend window is enforced by default and cleared by /__dev/reset", async () => {
    const mock = await startMock();
    try {
      const email = mock.email();
      assert.equal((await mock.otp(email)).status, 200);
      assert.equal((await mock.otp(email)).status, 429);
      await mock.dev("/__dev/reset");
      assert.equal((await mock.otp(email)).status, 200);
    } finally {
      await mock.stop();
    }
  });
});

describe("existing PostgREST profile endpoints", () => {
  const id = "11111111-2222-4333-8444-555555555555";
  const auth = { authorization: "Bearer service-role-for-tests" };

  it("GET returns MOCK_TIER (default pro) and PATCH changes it (204 for return=minimal)", async () => {
    const mock = await startMock();
    try {
      const get = () => mock.call("GET", `/rest/v1/profiles?id=eq.${id}&select=tier`, { headers: auth });
      assert.deepEqual((await get()).json, [{ tier: "pro" }]);
      const patch = await mock.call("PATCH", `/rest/v1/profiles?id=eq.${id}`, { body: { tier: "free" }, headers: { ...auth, prefer: "return=minimal" } });
      assert.equal(patch.status, 204);
      assert.deepEqual((await get()).json, [{ tier: "free" }]);
      const withBody = await mock.call("PATCH", `/rest/v1/profiles?id=eq.${id}`, { body: { tier: "pro" }, headers: auth });
      assert.deepEqual(withBody.json, [{ id, tier: "pro" }]);
    } finally {
      await mock.stop();
    }
  });

  it("MOCK_TIER=free is the default for unknown users", async () => {
    const mock = await startMock({ MOCK_TIER: "free" });
    try {
      const res = await mock.call("GET", `/rest/v1/profiles?id=eq.${id}&select=tier`, { headers: auth });
      assert.deepEqual(res.json, [{ tier: "free" }]);
    } finally {
      await mock.stop();
    }
  });

  it("rejects missing headers (401), a bad filter (400), a bad tier (400) and other methods (405)", async () => {
    const mock = await startMock();
    try {
      assert.equal((await mock.call("GET", `/rest/v1/profiles?id=eq.${id}`, { apikey: false, headers: auth })).status, 401);
      assert.equal((await mock.call("GET", `/rest/v1/profiles?id=eq.${id}`)).status, 401, "no Authorization header");
      assert.equal((await mock.call("GET", "/rest/v1/profiles?id=eq.nope", { headers: auth })).status, 400);
      assert.equal((await mock.call("PATCH", `/rest/v1/profiles?id=eq.${id}`, { body: { tier: "gold" }, headers: auth })).status, 400);
      assert.equal((await mock.call("DELETE", `/rest/v1/profiles?id=eq.${id}`, { headers: auth })).status, 405);
      assert.equal((await mock.call("GET", "/nope")).status, 404);
    } finally {
      await mock.stop();
    }
  });

  it("MOCK_FAIL=503 answers 503 to everything and MOCK_FAIL=drop closes the connection (dev routes stay reachable)", async () => {
    const down = await startMock({ MOCK_FAIL: "503" });
    try {
      assert.equal((await down.otp(down.email())).status, 503);
      assert.equal((await down.call("GET", `/rest/v1/profiles?id=eq.${id}`, { headers: auth })).status, 503);
      assert.equal((await down.dev("/__dev/reset")).status, 200);
    } finally {
      await down.stop();
    }
    const dropped = await startMock({ MOCK_FAIL: "drop" });
    try {
      await assert.rejects(dropped.otp(dropped.email()));
    } finally {
      await dropped.stop();
    }
  });
});

// Finding 2 (security review): referral.ts's real (non-mock) Supabase REST path had zero
// integration coverage before these routes existed on the mock. These tests hit the mock the
// way referral.ts actually does (referral_code lookup on /rest/v1/profiles, then GET/POST on
// /rest/v1/referrals), same auth-header contract as the profiles routes above.
describe("PostgREST referral endpoints (referral.ts's real query path)", () => {
  const referrerId = "22222222-3333-4444-8888-999999999999";
  const refereeId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  const auth = { authorization: "Bearer service-role-for-tests" };

  it("GET /rest/v1/profiles?referral_code=eq.<code> resolves a code seeded via /__dev/set-referral-code, and [] for an unknown one", async () => {
    const mock = await startMock();
    try {
      assert.equal((await mock.dev("/__dev/set-referral-code", { id: referrerId, code: "abcd1234" })).status, 200);
      const found = await mock.call("GET", "/rest/v1/profiles?referral_code=eq.abcd1234&select=id", { headers: auth });
      assert.deepEqual(found.json, [{ id: referrerId }]);
      const missing = await mock.call("GET", "/rest/v1/profiles?referral_code=eq.nosuchcode&select=id", { headers: auth });
      assert.deepEqual(missing.json, []);
    } finally {
      await mock.stop();
    }
  });

  it("referral_code lookup requires the same headers as the id filter (401) and only GET (405)", async () => {
    const mock = await startMock();
    try {
      assert.equal((await mock.call("GET", "/rest/v1/profiles?referral_code=eq.abcd1234&select=id", { apikey: false, headers: auth })).status, 401);
      assert.equal((await mock.call("GET", "/rest/v1/profiles?referral_code=eq.abcd1234&select=id")).status, 401, "no Authorization header");
      assert.equal((await mock.call("PATCH", "/rest/v1/profiles?referral_code=eq.abcd1234", { body: { tier: "pro" }, headers: auth })).status, 405);
    } finally {
      await mock.stop();
    }
  });

  it("GET /rest/v1/referrals?referee_id=eq.<uuid> is [] before redemption, then the row after POST", async () => {
    const mock = await startMock();
    try {
      const lookup = () => mock.call("GET", `/rest/v1/referrals?referee_id=eq.${refereeId}&select=id`, { headers: auth });
      assert.deepEqual((await lookup()).json, []);
      const posted = await mock.call("POST", "/rest/v1/referrals", {
        body: { referrer_id: referrerId, referee_id: refereeId, code: "abcd1234" },
        headers: { ...auth, prefer: "return=representation" },
      });
      assert.equal(posted.status, 201);
      assert.equal(posted.json.length, 1);
      assert.equal(posted.json[0].referrer_id, referrerId);
      assert.equal(posted.json[0].referee_id, refereeId);
      const after = await lookup();
      assert.equal(after.json.length, 1);
    } finally {
      await mock.stop();
    }
  });

  it("POST rejects self-referral (23514) and a second row for the same referee (23505), mirroring 0002_referrals.sql", async () => {
    const mock = await startMock();
    try {
      const selfPost = await mock.call("POST", "/rest/v1/referrals", { body: { referrer_id: refereeId, referee_id: refereeId, code: "x" }, headers: auth });
      assert.equal(selfPost.status, 400);
      assert.equal(selfPost.json.code, "23514");

      const first = await mock.call("POST", "/rest/v1/referrals", { body: { referrer_id: referrerId, referee_id: refereeId, code: "x" }, headers: auth });
      assert.equal(first.status, 201);
      const second = await mock.call("POST", "/rest/v1/referrals", {
        body: { referrer_id: "33333333-4444-4555-8666-777777777777", referee_id: refereeId, code: "y" },
        headers: auth,
      });
      assert.equal(second.status, 409);
      assert.equal(second.json.code, "23505");
    } finally {
      await mock.stop();
    }
  });

  it("rejects missing headers (401), a bad body (400) and other methods (405) on /rest/v1/referrals", async () => {
    const mock = await startMock();
    try {
      assert.equal((await mock.call("GET", `/rest/v1/referrals?referee_id=eq.${refereeId}`, { apikey: false, headers: auth })).status, 401);
      assert.equal((await mock.call("GET", `/rest/v1/referrals?referee_id=eq.${refereeId}`)).status, 401, "no Authorization header");
      assert.equal((await mock.call("GET", "/rest/v1/referrals?referee_id=eq.not-a-uuid", { headers: auth })).status, 400);
      assert.equal((await mock.call("POST", "/rest/v1/referrals", { body: { referrer_id: referrerId }, headers: auth })).status, 400);
      assert.equal((await mock.call("DELETE", `/rest/v1/referrals?referee_id=eq.${refereeId}`, { headers: auth })).status, 405);
    } finally {
      await mock.stop();
    }
  });

  it("fail: `referrals` covers the PostgREST route", async () => {
    const mock = await startMock();
    try {
      await mock.dev("/__dev/fail", { route: "referrals", mode: "503" });
      const res = await mock.call("GET", `/rest/v1/referrals?referee_id=eq.${refereeId}`, { headers: auth });
      assert.equal(res.status, 503);
    } finally {
      await mock.stop();
    }
  });

  it("/__dev/reset forgets seeded codes and recorded referrals", async () => {
    const mock = await startMock();
    try {
      await mock.dev("/__dev/set-referral-code", { id: referrerId, code: "abcd1234" });
      await mock.call("POST", "/rest/v1/referrals", { body: { referrer_id: referrerId, referee_id: refereeId, code: "abcd1234" }, headers: auth });
      assert.equal((await mock.dev("/__dev/reset")).status, 200);
      assert.deepEqual((await mock.call("GET", "/rest/v1/profiles?referral_code=eq.abcd1234&select=id", { headers: auth })).json, []);
      assert.deepEqual((await mock.call("GET", `/rest/v1/referrals?referee_id=eq.${refereeId}`, { headers: auth })).json, []);
    } finally {
      await mock.stop();
    }
  });
});

describe("MOCK_JWT_MODE=es256 (for running the Worker in jwks mode)", () => {
  it("serves the public key at the JWKS URL, signs ES256 tokens with its kid, and jose verifies them with the jwks-mode options", async () => {
    const mock = await startMock({ MOCK_JWT_MODE: "es256", SUPABASE_JWT_SECRET: undefined });
    try {
      const jwksRes = await mock.call("GET", "/auth/v1/.well-known/jwks.json", { apikey: false }); // public: no apikey
      assert.equal(jwksRes.status, 200);
      assert.equal(jwksRes.json.keys.length, 1);
      const [key] = jwksRes.json.keys;
      assert.deepEqual([key.kty, key.crv, key.alg, key.use, key.kid], ["EC", "P-256", "ES256", "sig", "mock-es256-1"]);
      assert.equal(key.d, undefined, "the private key must never be served");

      const s = await mock.signIn();
      assert.deepEqual(
        [decodeProtectedHeader(s.access_token).alg, decodeProtectedHeader(s.access_token).kid],
        ["ES256", "mock-es256-1"]
      );
      const { payload } = await jwtVerify(s.access_token, createLocalJWKSet(jwksRes.json), {
        algorithms: ["ES256", "RS256"], // src/auth.ts jwks mode
        audience: "authenticated",
        issuer: ISSUER,
        requiredClaims: ["exp", "sub"],
      });
      assert.equal(payload.sub, s.user.id);
      assert.match(payload.sub, UUID);
      // An HS256-only verifier (the Worker's hs256 mode) must not accept it.
      await assert.rejects(verifyLikeTheWorker(s.access_token));
      // Refresh and logout work in this mode too.
      const refreshed = await mock.refresh(s.refresh_token);
      assert.equal(refreshed.status, 200);
      assert.equal(decodeProtectedHeader(refreshed.json.access_token).alg, "ES256");
      assert.equal((await mock.logout(refreshed.json.access_token)).status, 204);
      assert.equal((await mock.refresh(refreshed.json.refresh_token)).json.error_code, "refresh_token_not_found");
      // A token forged with another key is refused by logout.
      const forged = await mock.logout(s.access_token.split(".").slice(0, 2).join(".") + "." + "A".repeat(86));
      assert.equal(forged.status, 401);
    } finally {
      await mock.stop();
    }
  });

  it("in the default hs256 mode the JWKS endpoint serves an empty key set, like a legacy project", async () => {
    const mock = await startMock();
    try {
      const res = await mock.call("GET", "/auth/v1/.well-known/jwks.json", { apikey: false });
      assert.deepEqual(res.json, { keys: [] });
      assert.equal((await mock.call("POST", "/auth/v1/.well-known/jwks.json", { body: {} })).status, 405);
    } finally {
      await mock.stop();
    }
  });

  it("rejects an unknown MOCK_JWT_MODE", async () => {
    const child = spawn(process.execPath, [MOCK], { env: { ...process.env, PORT: "0", SUPABASE_JWT_SECRET: SECRET, MOCK_JWT_MODE: "rs256" }, stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    child.stderr.on("data", (d) => (err += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
    const code = await new Promise((resolve) => child.on("exit", resolve));
    clearTimeout(timer);
    assert.equal(typeof code, "number", "the mock kept running instead of exiting");
    assert.notEqual(code, 0);
    assert.match(err, /MOCK_JWT_MODE/);
  });
});

describe("secrets and logs", () => {
  it("never prints a token, the signing secret or the apikey; only the code line carries a secret", async () => {
    const mock = await startMock();
    try {
      const s = await mock.signIn();
      await mock.refresh(s.refresh_token);
      await mock.logout(s.access_token);
      const output = mock.stdout() + mock.stderr();
      for (const secret of [SECRET, s.access_token, s.refresh_token, "anon-key-for-tests"]) {
        assert.ok(!output.includes(secret), "leaked a secret to the console");
      }
    } finally {
      await mock.stop();
    }
  });
});
