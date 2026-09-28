import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { exportJWK, exportSPKI, generateKeyPair, type JWK } from "jose";
import {
  ISSUER,
  SUPABASE_URL,
  call,
  freezeClock,
  hang,
  installUpstream,
  jsonReply,
  makeEnv,
  mintToken,
  newUserId,
  restoreClock,
  restoreUpstream,
  tierReply,
  type Upstream,
} from "./helpers";
import { EXAMPLE_JWT_SECRET } from "../src/hostGuard";

/**
 * Task 2.3: access-token verification in `hs256` and `jwks` modes (docs/auth-design.md section 4).
 * Every request goes through the Worker's fetch handler. The JWKS is served by the fetch mock in
 * helpers.ts. auth.ts caches key sets per JWKS URL for the life of the isolate, so each test uses
 * its own URL (a different path on the project origin) unless it is testing the default URL.
 */

type Alg = "ES256" | "RS256";
interface TestKey {
  alg: Alg;
  kid: string;
  privateKey: CryptoKey;
  publicKey: CryptoKey;
  jwk: JWK;
}

async function makeKey(alg: Alg, kid: string): Promise<TestKey> {
  const { publicKey, privateKey } = await generateKeyPair(alg, { extractable: true });
  const jwk = { ...(await exportJWK(publicKey)), kid, alg, use: "sig" };
  return { alg, kid, privateKey: privateKey as CryptoKey, publicKey: publicKey as CryptoKey, jwk };
}

let es: TestKey; // the project's ES256 signing key
let rs: TestKey; // the project's RS256 signing key
let other: TestKey; // an attacker's ES256 key

beforeAll(async () => {
  es = await makeKey("ES256", "es-key-1");
  rs = await makeKey("RS256", "rs-key-1");
  other = await makeKey("ES256", "es-key-1"); // same kid as the real key, different key material
});

let upstream: Upstream;
let counter = 0;
const nextJwksUrl = () => `${SUPABASE_URL}/auth/v1/jwks-test/${++counter}.json`;
const DEFAULT_JWKS_URL = `${SUPABASE_URL}/auth/v1/.well-known/jwks.json`;

beforeEach(() => {
  upstream = installUpstream();
});
afterEach(() => {
  restoreClock();
  restoreUpstream();
  vi.restoreAllMocks();
});

const isJwks = (url: string) => url.includes("/jwks-test/") || url.endsWith("/.well-known/jwks.json");
const jwksFetches = () => upstream.calls.filter((c) => isJwks(c.url));

/** Serves `keys()` at any JWKS URL and Pro tier for everything else on the project origin. */
function serveJwks(keys: () => JWK[] = () => [es.jwk, rs.jwk]) {
  upstream.supabase = (request) => (isJwks(request.url) ? jsonReply({ keys: keys() }) : tierReply("pro"));
}

function jwksEnv(url: string | undefined = nextJwksUrl(), extra: Parameters<typeof makeEnv>[0] = {}) {
  return makeEnv({ JWT_VERIFY_MODE: "jwks", SUPABASE_JWT_SECRET: undefined, SUPABASE_JWKS_URL: url, ...extra });
}

const rewrite = (token: string | null, env = jwksEnv(), host?: string) =>
  call({ token, json: { transcript: "hello world" }, env, host });

async function expectError(res: Response, status: number, error: string) {
  expect(res.status).toBe(status);
  expect(await res.json()).toEqual({ error });
}

const b64url = (input: string) => btoa(input).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");

/** A token with `alg: none` and no signature. */
function unsignedToken(claims: Record<string, unknown> = {}): string {
  const now = Math.floor(Date.now() / 1000);
  const payload = { sub: newUserId(), iss: ISSUER, aud: "authenticated", exp: now + 3600, ...claims };
  return `${b64url(JSON.stringify({ alg: "none", typ: "JWT" }))}.${b64url(JSON.stringify(payload))}.`;
}

const es256 = (opts: Parameters<typeof mintToken>[0] = {}) => mintToken({ alg: "ES256", key: es.privateKey, kid: es.kid, ...opts });
const rs256 = (opts: Parameters<typeof mintToken>[0] = {}) => mintToken({ alg: "RS256", key: rs.privateKey, kid: rs.kid, ...opts });

// ---------------------------------------------------------------------------

describe("hs256 mode (the default)", () => {
  it("accepts a valid HS256 token, with the mode explicit or unset", async () => {
    for (const mode of ["hs256", undefined]) {
      const res = await call({ token: await mintToken(), json: { transcript: "hello" }, env: makeEnv({ JWT_VERIFY_MODE: mode }) });
      expect(res.status).toBe(200);
    }
  });

  it("rejects a token signed with the wrong secret", async () => {
    const token = await mintToken({ secret: "some-other-secret-0123456789abcdef0123456789" });
    await expectError(await rewrite(token, makeEnv({ JWT_VERIFY_MODE: "hs256" })), 401, "unauthorized");
  });

  it("rejects ES256 and RS256 tokens, even from a key the JWKS would trust, and fetches nothing", async () => {
    serveJwks();
    for (const token of [await es256(), await rs256()]) {
      await expectError(await rewrite(token, makeEnv({ JWT_VERIFY_MODE: "hs256", SUPABASE_JWKS_URL: nextJwksUrl() })), 401, "unauthorized");
    }
    expect(jwksFetches()).toHaveLength(0);
  });

  it("rejects HS384 and HS512 tokens even with the right secret", async () => {
    for (const alg of ["HS384", "HS512"]) {
      await expectError(await rewrite(await mintToken({ alg }), makeEnv()), 401, "unauthorized");
    }
  });

  it("rejects an unsigned token (alg none)", async () => {
    await expectError(await rewrite(unsignedToken(), makeEnv()), 401, "unauthorized");
    await expectError(await rewrite(unsignedToken().slice(0, -1), makeEnv()), 401, "unauthorized"); // no trailing dot
  });

  it("makes no JWKS request and ignores SUPABASE_JWKS_URL, even a bad one off loopback", async () => {
    serveJwks();
    const env = makeEnv({ SUPABASE_JWKS_URL: "http://attacker.example/jwks.json" });
    const res = await call({ token: await mintToken(), json: { transcript: "hello" }, env, host: "api.example.com" });
    expect(res.status).toBe(200);
    expect(jwksFetches()).toHaveLength(0);
    expect(upstream.calls.some((c) => c.url.includes("attacker.example"))).toBe(false);
  });

  it("with no secret configured: 401 on loopback (fail closed), 500 misconfigured off loopback", async () => {
    const env = makeEnv({ JWT_VERIFY_MODE: "hs256", SUPABASE_JWT_SECRET: undefined });
    await expectError(await rewrite(await mintToken(), env), 401, "unauthorized");
    await expectError(await rewrite(await mintToken(), env, "api.example.com"), 500, "misconfigured");
    await expectError(await rewrite(await mintToken(), makeEnv({ SUPABASE_JWT_SECRET: "" })), 401, "unauthorized");
  });
});

describe("invalid JWT_VERIFY_MODE fails closed", () => {
  it.each(["HS256", "JWKS", "Jwks", "", " jwks", "hs256 ", "es256", "none", "false", "0"])("mode %j answers 500 misconfigured before anything else", async (mode) => {
    serveJwks();
    for (const host of ["localhost", "api.example.com"]) {
      const res = await call({ token: await mintToken(), json: { transcript: "hello" }, env: makeEnv({ JWT_VERIFY_MODE: mode }), host });
      await expectError(res, 500, "misconfigured");
    }
    expect(upstream.calls).toHaveLength(0);
  });

  it("logs one fixed line and nothing from the token or config", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const token = await mintToken();
    await rewrite(token, makeEnv({ JWT_VERIFY_MODE: "bogus-mode-CANARY" }));
    expect(errorSpy).toHaveBeenCalledTimes(1);
    const line = String(errorSpy.mock.calls[0][0]);
    expect(line).toBe("misconfigured: JWT_VERIFY_MODE must be hs256 or jwks");
    expect(line).not.toContain("CANARY");
  });
});

describe("jwks mode: valid tokens", () => {
  it("accepts ES256 and RS256 tokens whose kid is in the JWKS", async () => {
    serveJwks();
    const env = jwksEnv();
    expect((await rewrite(await es256(), env)).status).toBe(200);
    expect((await rewrite(await rs256(), env)).status).toBe(200);
  });

  it("needs no SUPABASE_JWT_SECRET, also off loopback", async () => {
    serveJwks();
    const env = jwksEnv(undefined, { SUPABASE_JWT_SECRET: undefined });
    expect((await rewrite(await es256(), env)).status).toBe(200);
    expect((await rewrite(await es256(), env, "api.example.com")).status).toBe(200);
  });

  it("does not apply the local-dev secret guard, since it holds no secret", async () => {
    serveJwks();
    const env = jwksEnv(undefined, { SUPABASE_JWT_SECRET: EXAMPLE_JWT_SECRET });
    expect((await rewrite(await es256(), env, "api.example.com")).status).toBe(200);
  });

  it("uses the default JWKS URL under the project's origin, also with a trailing slash on SUPABASE_URL", async () => {
    // The only test that touches the default URL: its key set stays cached for the rest of this file.
    serveJwks();
    const env = makeEnv({ JWT_VERIFY_MODE: "jwks", SUPABASE_JWT_SECRET: undefined, SUPABASE_JWKS_URL: undefined, SUPABASE_URL: `${SUPABASE_URL}//` });
    expect((await rewrite(await es256(), env)).status).toBe(200);
    expect(jwksFetches().map((c) => c.url)).toEqual([DEFAULT_JWKS_URL]);
    expect(jwksFetches()[0].method).toBe("GET");
  });

  it("accepts an aud list that contains authenticated", async () => {
    serveJwks();
    expect((await rewrite(await es256({ aud: ["authenticated", "other"] }), jwksEnv())).status).toBe(200);
  });
});

describe("jwks mode: rejected tokens (401)", () => {
  it("rejects HS256 tokens, even with the right secret, without fetching keys", async () => {
    serveJwks();
    const env = jwksEnv(undefined, { SUPABASE_JWT_SECRET: "test-jwt-secret-CANARY-0123456789abcdef0123456789" });
    await expectError(await rewrite(await mintToken({ kid: es.kid }), env), 401, "unauthorized");
    expect(jwksFetches()).toHaveLength(0);
  });

  it("rejects HS384, HS512 and PS256 tokens", async () => {
    serveJwks();
    const pss = await generateKeyPair("PS256");
    for (const token of [await mintToken({ alg: "HS384", kid: es.kid }), await mintToken({ alg: "HS512", kid: es.kid })]) {
      await expectError(await rewrite(token), 401, "unauthorized");
    }
    const ps256 = await mintToken({ alg: "PS256", key: pss.privateKey, kid: es.kid });
    await expectError(await rewrite(ps256), 401, "unauthorized");
  });

  it("rejects alg none", async () => {
    serveJwks();
    await expectError(await rewrite(unsignedToken()), 401, "unauthorized");
    const withKid = `${b64url(JSON.stringify({ alg: "none", kid: es.kid }))}.${unsignedToken().split(".")[1]}.`;
    await expectError(await rewrite(withKid), 401, "unauthorized");
  });

  it("algorithm confusion: an HS256 token signed with the public key bytes is rejected", async () => {
    serveJwks();
    const spki = await exportSPKI(es.publicKey);
    const rsSpki = await exportSPKI(rs.publicKey);
    for (const bytes of [
      new TextEncoder().encode(spki),
      new TextEncoder().encode(JSON.stringify(es.jwk)),
      new TextEncoder().encode(rsSpki),
      new TextEncoder().encode(JSON.stringify(rs.jwk)),
    ]) {
      const token = await mintToken({ alg: "HS256", key: bytes, kid: es.kid });
      await expectError(await rewrite(token), 401, "unauthorized");
    }
  });

  it("rejects a token signed with a different private key under a known kid", async () => {
    serveJwks();
    const forged = await mintToken({ alg: "ES256", key: other.privateKey, kid: es.kid });
    await expectError(await rewrite(forged), 401, "unauthorized");
  });

  it("rejects a tampered payload", async () => {
    serveJwks();
    const [head, , sig] = (await es256()).split(".");
    const evil = b64url(JSON.stringify({ sub: newUserId(), iss: ISSUER, aud: "authenticated", exp: Math.floor(Date.now() / 1000) + 3600 }));
    await expectError(await rewrite(`${head}.${evil}.${sig}`), 401, "unauthorized");
  });

  it("an unknown kid is 401, never 503, when the JWKS itself is fine", async () => {
    serveJwks();
    const token = await mintToken({ alg: "ES256", key: other.privateKey, kid: "no-such-key" });
    await expectError(await rewrite(token), 401, "unauthorized");
  });

  it("a token with no kid is 401 when the JWKS holds two candidate keys of that algorithm", async () => {
    const second = await makeKey("ES256", "es-key-2");
    serveJwks(() => [es.jwk, second.jwk]);
    const token = await mintToken({ alg: "ES256", key: es.privateKey });
    await expectError(await rewrite(token), 401, "unauthorized");
  });

  it("an RS256 token is 401 when the JWKS only has an ES256 key", async () => {
    serveJwks(() => [es.jwk]);
    await expectError(await rewrite(await rs256()), 401, "unauthorized");
  });

  it("still enforces iss, aud, exp and a UUID sub", async () => {
    serveJwks();
    const env = jwksEnv();
    const bad: Record<string, Parameters<typeof mintToken>[0]> = {
      "wrong issuer": { iss: "https://other-project.supabase.test/auth/v1" },
      "no issuer": { iss: null },
      "wrong audience": { aud: "anon" },
      "no audience": { aud: null },
      "audience list without authenticated": { aud: ["anon", "service_role"] },
      expired: { expiresIn: -60 },
      "no exp": { expiresIn: null },
      "no sub": { sub: null },
      "non-UUID sub": { sub: "not-a-uuid" },
      "sub with a path": { sub: "00000000-0000-4000-8000-000000000001/../x" },
    };
    for (const [name, opts] of Object.entries(bad)) {
      const res = await rewrite(await es256(opts), env);
      expect(res.status, name).toBe(401);
    }
    expect((await rewrite(await es256(), env)).status).toBe(200);
  });

  it("does not follow jku, x5u or an embedded jwk header, and a token that only trusts them is 401", async () => {
    serveJwks();
    const env = jwksEnv();
    // A valid token with a jku header: the header is ignored, no request is made to it.
    const withJku = await es256({ header: { jku: "https://attacker.example/jwks.json", x5u: "https://attacker.example/cert.pem" } });
    expect((await rewrite(withJku, env)).status).toBe(200);
    // An attacker signs with their own key, unknown kid, and embeds the matching public key.
    const attackerJwk = { ...other.jwk, kid: "attacker-key" };
    const forged = await mintToken({
      alg: "ES256",
      key: other.privateKey,
      kid: "attacker-key",
      header: { jwk: attackerJwk, jku: "https://attacker.example/jwks.json" },
    });
    await expectError(await rewrite(forged, env), 401, "unauthorized");
    expect(upstream.calls.some((c) => c.url.includes("attacker.example"))).toBe(false);
  });
});

describe("jwks mode: caching, rotation and cooldown", () => {
  it("fetches the JWKS once for many requests", async () => {
    serveJwks();
    const env = jwksEnv();
    for (let i = 0; i < 4; i++) expect((await rewrite(await es256(), env)).status).toBe(200);
    expect((await rewrite(await rs256(), env)).status).toBe(200);
    expect(jwksFetches()).toHaveLength(1);
  });

  it("concurrent requests on a cold cache all succeed", async () => {
    serveJwks();
    const env = jwksEnv();
    const tokens = await Promise.all([1, 2, 3, 4, 5].map(() => es256()));
    const results = await Promise.all(tokens.map((t) => rewrite(t, env)));
    expect(results.map((r) => r.status)).toEqual([200, 200, 200, 200, 200]);
  });

  it("picks up a rotated-in key only after the 30 s cooldown, and refreshes the set after 10 minutes", async () => {
    const clock = freezeClock();
    const next = await makeKey("ES256", "es-key-rotated");
    let keys = [es.jwk];
    serveJwks(() => keys);
    const env = jwksEnv();
    const nextToken = () => mintToken({ alg: "ES256", key: next.privateKey, kid: next.kid });

    expect((await rewrite(await es256(), env)).status).toBe(200);
    expect(jwksFetches()).toHaveLength(1);

    keys = [es.jwk, next.jwk]; // the project rotates a new key in
    clock.advance(1_000);
    await expectError(await rewrite(await nextToken(), env), 401, "unauthorized"); // cooling down: no refetch
    expect(jwksFetches()).toHaveLength(1);

    clock.advance(31_000);
    expect((await rewrite(await nextToken(), env)).status).toBe(200); // cooldown over: one refetch
    expect(jwksFetches()).toHaveLength(2);

    clock.advance(601_000);
    expect((await rewrite(await es256(), env)).status).toBe(200); // cache older than 10 minutes: refetch
    expect(jwksFetches()).toHaveLength(3);
  });

  it("a rotated-out key stops working once the set is refetched", async () => {
    const clock = freezeClock();
    let keys = [es.jwk];
    serveJwks(() => keys);
    const env = jwksEnv();
    expect((await rewrite(await es256(), env)).status).toBe(200);
    keys = [rs.jwk];
    clock.advance(601_000);
    await expectError(await rewrite(await es256(), env), 401, "unauthorized");
    expect((await rewrite(await rs256(), env)).status).toBe(200);
  });

  it("keeps serving from the cached keys while the JWKS endpoint is down, until the cache expires", async () => {
    const clock = freezeClock();
    serveJwks();
    const env = jwksEnv();
    expect((await rewrite(await es256(), env)).status).toBe(200);
    upstream.supabase = (request) => (isJwks(request.url) ? new Response("down", { status: 500 }) : tierReply("pro"));
    clock.advance(60_000);
    expect((await rewrite(await es256(), env)).status).toBe(200);
    // An unknown kid inside the cooldown is still a plain 401: no refetch was tried.
    clock.advance(-40_000);
    await expectError(await rewrite(await mintToken({ alg: "ES256", key: other.privateKey, kid: "unknown" }), env), 401, "unauthorized");
    // Past the 10 minute cache age the refetch fails: 503.
    clock.advance(700_000);
    await expectError(await rewrite(await es256(), env), 503, "service_unavailable");
  });
});

describe("jwks mode: the key source failing is 503, not 401", () => {
  const outages: Record<string, () => Response | Promise<Response>> = {
    "HTTP 500": () => new Response("boom", { status: 500 }),
    "HTTP 503": () => new Response("busy", { status: 503 }),
    "HTTP 404": () => new Response("nope", { status: 404 }),
    "a redirect": () => new Response(null, { status: 302, headers: { location: "https://attacker.example/jwks.json" } }),
    "a network error": () => {
      throw new TypeError("network down");
    },
    "a body that is not JSON": () => new Response("<html>not json</html>", { status: 200 }),
    "JSON that is not a key set": () => jsonReply({ keys: "nope" }),
    "a JSON array": () => jsonReply([]),
    "a key set with no keys (a legacy HS256 project)": () => jsonReply({ keys: [] }),
    "a key set whose keys are not objects": () => jsonReply({ keys: [1, "two"] }),
  };

  it.each(Object.keys(outages))("%s", async (name) => {
    upstream.supabase = (request) => (isJwks(request.url) ? outages[name]() : tierReply("pro"));
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const token = await es256();
    const res = await rewrite(token);
    await expectError(res, 503, "service_unavailable");
    // No tier lookup, no provider call, and nothing but the fixed log line.
    expect(upstream.supabaseCalls().every((c) => isJwks(c.url))).toBe(true);
    expect(upstream.anthropicCalls()).toHaveLength(0);
    expect(errorSpy).not.toHaveBeenCalled();
    const lines = logSpy.mock.calls.map((c) => String(c[0]));
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0])).toMatchObject({ event: "rewrite", status: 503, error: "tier_lookup_failed", user: null });
    expect(lines.join("\n")).not.toContain(token);
    expect(lines.join("\n")).not.toContain("attacker.example");
  });

  it("a hung JWKS endpoint is a 503 after the 3 s timeout", async () => {
    upstream.supabase = (request) => (isJwks(request.url) ? hang(request) : tierReply("pro"));
    const started = Date.now();
    const res = await rewrite(await es256());
    await expectError(res, 503, "service_unavailable");
    const took = Date.now() - started;
    expect(took).toBeGreaterThanOrEqual(2900);
    expect(took).toBeLessThan(6000);
  }, 15_000);

  it("recovers on the next request once the endpoint is back (a failed fetch is not cached)", async () => {
    let up = false;
    upstream.supabase = (request) => (isJwks(request.url) ? (up ? jsonReply({ keys: [es.jwk] }) : new Response("down", { status: 500 })) : tierReply("pro"));
    const env = jwksEnv();
    await expectError(await rewrite(await es256(), env), 503, "service_unavailable");
    await expectError(await rewrite(await es256(), env), 503, "service_unavailable");
    up = true;
    expect((await rewrite(await es256(), env)).status).toBe(200);
  });

  it("a token that is bad on its face never reaches the JWKS, so it is a 401 even while the endpoint is down", async () => {
    upstream.supabase = (request) => (isJwks(request.url) ? new Response("down", { status: 500 }) : tierReply("pro"));
    const env = jwksEnv();
    for (const token of ["garbage", await mintToken(), unsignedToken(), await mintToken({ alg: "HS384" })]) {
      await expectError(await rewrite(token, env), 401, "unauthorized");
    }
    await expectError(await rewrite(null, env), 401, "unauthorized");
    expect(jwksFetches()).toHaveLength(0);
  });
});

describe("jwks mode: JWKS URL configuration", () => {
  const offLoopback = "api.example.com";

  it.each([
    ["http on the project host", `${SUPABASE_URL.replace("https:", "http:")}/auth/v1/jwks-test/x.json`],
    ["https on another host", "https://attacker.example/jwks.json"],
    ["https on a subdomain of the project", "https://evil.test-project.supabase.test/jwks.json"],
    ["credentials in the URL", "https://user:pw@test-project.supabase.test/jwks.json"],
    ["a non-http scheme", "file:///etc/passwd"],
    ["not a URL", "not a url"],
  ])("off loopback, %s is 500 misconfigured and nothing is fetched", async (_name, url) => {
    serveJwks();
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const res = await rewrite(await es256(), jwksEnv(url), offLoopback);
    await expectError(res, 500, "misconfigured");
    expect(upstream.calls).toHaveLength(0);
    expect(errorSpy).toHaveBeenCalledTimes(1);
    expect(String(errorSpy.mock.calls[0][0])).not.toContain(url);
  });

  it("off loopback, an unparseable SUPABASE_URL is 500 misconfigured", async () => {
    const res = await rewrite(await es256(), jwksEnv(undefined, { SUPABASE_URL: "" }), offLoopback);
    await expectError(res, 500, "misconfigured");
  });

  it("off loopback, https on the project origin is accepted (any path)", async () => {
    serveJwks();
    expect((await rewrite(await es256(), jwksEnv(`${SUPABASE_URL}/auth/v1/jwks-test/${++counter}.json?x=1`), offLoopback)).status).toBe(200);
  });

  it("on loopback the guard does not apply: a plain-http URL is tried (and fails as an outage), not refused", async () => {
    // The fetch mock refuses any origin it does not know, so reaching the fetch shows the guard let it through.
    const url = "http://127.0.0.1:54321/auth/v1/.well-known/jwks.json";
    const res = await rewrite(await es256(), jwksEnv(url), "localhost");
    await expectError(res, 503, "service_unavailable");
    expect(upstream.calls.map((c) => c.url)).toEqual([url]);
  });
});
