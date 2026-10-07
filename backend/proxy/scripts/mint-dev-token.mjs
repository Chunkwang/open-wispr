#!/usr/bin/env node
// Mints a local HS256 JWT shaped like a Supabase session token, for calling the
// proxy under `wrangler dev`. Dev only: the secret is whatever you put in
// .dev.vars, never a real project's secret.
//
// The token's issuer is `${SUPABASE_URL}/auth/v1`, with SUPABASE_URL taken from the
// env var, else .dev.vars, else http://127.0.0.1:54321 (the mock Supabase).
//
// Usage:
//   node scripts/mint-dev-token.mjs [user-id] [--ttl <seconds>]
//   curl -H "Authorization: Bearer $(node scripts/mint-dev-token.mjs)" ...
//
// Prints only the token to stdout. Errors go to stderr with a non-zero exit.

import { SignJWT } from "jose";
import { readDevVar } from "./lib/dev-vars.mjs";

const DEFAULT_USER_ID = "00000000-0000-4000-8000-000000000001";
const DEFAULT_TTL_SECONDS = 3600;
const DEFAULT_SUPABASE_URL = "http://127.0.0.1:54321";

function fail(message) {
  process.stderr.write(`mint-dev-token: ${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  let userId = DEFAULT_USER_ID;
  let ttl = DEFAULT_TTL_SECONDS;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--ttl" || arg.startsWith("--ttl=")) {
      const value = arg === "--ttl" ? argv[++i] : arg.slice("--ttl=".length);
      ttl = Number(value);
      if (!Number.isInteger(ttl) || ttl <= 0) fail(`--ttl must be a positive integer number of seconds, got "${value}"`);
    } else if (arg.startsWith("--")) {
      fail(`unknown option ${arg}. Usage: mint-dev-token.mjs [user-id] [--ttl <seconds>]`);
    } else {
      userId = arg;
    }
  }
  return { userId, ttl };
}

const { userId, ttl } = parseArgs(process.argv.slice(2));
// The Worker only accepts UUID subjects (as Supabase issues), so refuse anything else here.
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(userId)) {
  fail(`user id must be a UUID (the Worker rejects any other subject), got "${userId}"`);
}
const secret = process.env.SUPABASE_JWT_SECRET || readDevVar("SUPABASE_JWT_SECRET");
if (!secret) {
  fail(
    "SUPABASE_JWT_SECRET is not set. Export it, or copy .dev.vars.example to .dev.vars " +
      "in backend/proxy and set a local dev value there."
  );
}

// Guard against minting production tokens: a real project secret exported in
// this shell must not be usable here. Local secrets carry a `local-dev-` prefix
// (see .dev.vars.example); anything else is refused.
if (!secret.startsWith("local-dev-")) {
  fail(
    "refusing to sign with a secret that does not start with \"local-dev-\". " +
      "This script is for local dev only; never use a real Supabase JWT secret here."
  );
}

// The Worker requires iss === `${SUPABASE_URL}/auth/v1` and aud === "authenticated".
// Derive the issuer from the same SUPABASE_URL the Worker will run with.
const supabaseUrl = (process.env.SUPABASE_URL || readDevVar("SUPABASE_URL") || DEFAULT_SUPABASE_URL).replace(/\/+$/, "");

const token = await new SignJWT({ aud: "authenticated", role: "authenticated" })
  .setProtectedHeader({ alg: "HS256", typ: "JWT" })
  .setIssuer(`${supabaseUrl}/auth/v1`)
  .setSubject(userId)
  .setIssuedAt()
  .setExpirationTime(`${ttl}s`)
  .sign(new TextEncoder().encode(secret));

process.stdout.write(`${token}\n`);
