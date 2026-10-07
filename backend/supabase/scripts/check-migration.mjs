#!/usr/bin/env node
// Offline sanity check for backend/supabase/migrations/*.sql, run against PGlite (WASM
// Postgres). It is NOT a substitute for the Day 16 run against the real Supabase project
// with a real user token: the harness below only imitates Supabase's roles and default
// privileges, from memory of how Supabase behaves.
//
// PGlite is deliberately not in package.json. Install it in a scratch directory and point
// PGLITE_DIR at it:
//
//   mkdir -p /tmp/pglite && cd /tmp/pglite && npm init -y && npm install @electric-sql/pglite
//   PGLITE_DIR=/tmp/pglite node backend/supabase/scripts/check-migration.mjs
//
// Exit codes: 0 every assertion passed; 1 an assertion failed; 2 PGlite is not available
// (nothing was checked).

import { readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS = join(HERE, "..", "migrations");

const INSTALL_HELP = `PGlite (WASM Postgres) is needed to run this check and is not a project dependency.
Install it in a scratch directory and point PGLITE_DIR at it:

  mkdir -p /tmp/pglite && cd /tmp/pglite && npm init -y && npm install @electric-sql/pglite
  PGLITE_DIR=/tmp/pglite node backend/supabase/scripts/check-migration.mjs
`;

async function loadPglite() {
  const dir = process.env.PGLITE_DIR;
  if (!dir) {
    process.stderr.write(`check-migration: PGLITE_DIR is not set.\n${INSTALL_HELP}`);
    process.exit(2);
  }
  const req = createRequire(join(resolve(dir), "noop.js"));
  try {
    const entry = req.resolve("@electric-sql/pglite");
    return (await import(pathToFileURL(entry).href)).PGlite;
  } catch (first) {
    try {
      const fallback = join(resolve(dir), "node_modules", "@electric-sql", "pglite", "dist", "index.js");
      return (await import(pathToFileURL(fallback).href)).PGlite;
    } catch {
      process.stderr.write(`check-migration: could not load @electric-sql/pglite from ${dir} (${first.code ?? first.message}).\n${INSTALL_HELP}`);
      process.exit(2);
    }
  }
}

const PGlite = await loadPglite();
const db = new PGlite();

// ---------------------------------------------------------------------------
// Harness: roles, the auth schema and Supabase's default privileges, before any migration.
// ---------------------------------------------------------------------------

await db.exec(`
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;

  create schema if not exists auth;
  create table auth.users (id uuid primary key default gen_random_uuid(), email text);
  create function auth.uid() returns uuid language sql stable as $$
    select coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid
  $$;

  grant usage on schema auth to anon, authenticated, service_role;
  grant usage on schema public to anon, authenticated, service_role;
  grant execute on function auth.uid() to anon, authenticated, service_role;

  -- What makes the explicit REVOKE in the migration necessary: new public tables and
  -- functions are granted to the client-facing roles by default.
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
`);

const LEGACY = "00000000-0000-4000-8000-00000000000c"; // signed up before the migration
const USER_A = "00000000-0000-4000-8000-00000000000a";
const USER_B = "00000000-0000-4000-8000-00000000000b";
const USER_C = "00000000-0000-4000-8000-0000000000dd"; // signs up after a second run of the migration

await db.query("insert into auth.users (id, email) values ($1, 'legacy@example.com')", [LEGACY]);

const migrationFiles = readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort();
if (migrationFiles.length === 0) {
  process.stderr.write("check-migration: no migrations found\n");
  process.exit(1);
}
const applyMigrations = async () => {
  for (const file of migrationFiles) await db.exec(readFileSync(join(MIGRATIONS, file), "utf8"));
};

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

let failed = 0;
let passed = 0;

async function check(name, fn) {
  try {
    await fn();
    passed += 1;
    process.stdout.write(`PASS  ${name}\n`);
  } catch (error) {
    failed += 1;
    process.stdout.write(`FAIL  ${name}\n        ${String(error.message ?? error).split("\n")[0]}\n`);
  }
}

function ok(condition, message) {
  if (!condition) throw new Error(message);
}

/** Runs `sql` and requires it to fail with this SQLSTATE. */
async function denies(sql, sqlState, params = []) {
  try {
    await db.query(sql, params);
  } catch (error) {
    if (error.code === sqlState) return;
    throw new Error(`expected SQLSTATE ${sqlState} but got ${error.code}: ${error.message}`);
  }
  throw new Error(`expected SQLSTATE ${sqlState} but the statement succeeded: ${sql}`);
}

/** Runs `fn` as `role`, with a JWT-like claim set (sub) that auth.uid() reads, then switches back. */
async function asRole(role, sub, fn) {
  const claims = sub === null ? "{}" : JSON.stringify({ sub, role });
  await db.query("select set_config('request.jwt.claims', $1, false)", [claims]);
  await db.exec(`set role ${role}`);
  try {
    return await fn();
  } finally {
    await db.exec("reset role");
  }
}

const rows = async (sql, params = []) => (await db.query(sql, params)).rows;
const tierOf = async (id) => (await rows("select tier from public.profiles where id = $1", [id]))[0]?.tier;

/** The properties that must hold after every run of the migration. */
async function assertLockedDown() {
  await asRole("authenticated", USER_A, async () => {
    await denies("update public.profiles set tier = 'pro' where id = $1", "42501", [USER_A]);
    await denies("update public.profiles set tier = 'pro'", "42501");
    await denies("insert into public.profiles (id) values (gen_random_uuid())", "42501");
    await denies("delete from public.profiles where id = $1", "42501", [USER_A]);
    await denies("select stripe_customer_id from public.profiles", "42501");
  });
  await asRole("anon", null, async () => {
    await denies("update public.profiles set tier = 'pro'", "42501");
  });
}

// ---------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------

await applyMigrations();
await db.query("insert into auth.users (id, email) values ($1, 'a@example.com'), ($2, 'b@example.com')", [USER_A, USER_B]);

await check("a user who existed before the migration got a free profile (backfill)", async () => {
  ok((await tierOf(LEGACY)) === "free", "no free profile for the pre-existing user");
});

await check("inserting into auth.users creates a free profile with no Stripe customer (trigger)", async () => {
  const [row] = await rows("select tier, stripe_customer_id, created_at from public.profiles where id = $1", [USER_A]);
  ok(row?.tier === "free", "tier is not free");
  ok(row.stripe_customer_id === null, "stripe_customer_id is not null");
  ok(row.created_at !== null, "created_at not set");
});

await check("the table has no email column", async () => {
  const cols = (await rows("select column_name from information_schema.columns where table_schema = 'public' and table_name = 'profiles'")).map((r) => r.column_name).sort();
  ok(JSON.stringify(cols) === JSON.stringify(["created_at", "id", "referral_code", "stripe_customer_id", "tier"]), `columns are ${cols}`);
});

await check("RLS is enabled, and the only policy is SELECT for authenticated", async () => {
  const [cls] = await rows("select relrowsecurity from pg_class where oid = 'public.profiles'::regclass");
  ok(cls.relrowsecurity === true, "RLS is not enabled");
  const policies = await rows("select policyname, cmd, roles from pg_policies where schemaname = 'public' and tablename = 'profiles'");
  ok(policies.length === 1, `expected 1 policy, found ${policies.length}`);
  ok(policies[0].cmd === "SELECT", `policy command is ${policies[0].cmd}`);
  const roles = [].concat(policies[0].roles).join(",").replace(/[{}]/g, "");
  ok(roles === "authenticated", `policy roles are ${roles}`);
});

await check("user A sees only their own row (id, tier), never user B's", async () => {
  await asRole("authenticated", USER_A, async () => {
    const all = await rows("select id, tier from public.profiles");
    ok(all.length === 1 && all[0].id === USER_A, `A sees ${all.length} rows`);
    ok((await rows("select id from public.profiles where id = $1", [USER_B])).length === 0, "A can see B's row");
  });
  await asRole("authenticated", USER_B, async () => {
    const all = await rows("select id from public.profiles");
    ok(all.length === 1 && all[0].id === USER_B, `B sees ${all.length} rows`);
  });
});

await check("a session with no subject sees nothing", async () => {
  await asRole("authenticated", null, async () => {
    ok((await rows("select id from public.profiles")).length === 0, "rows visible without a sub");
  });
});

await check("a user cannot set their own tier (update denied, 42501), and the tier is unchanged", async () => {
  await asRole("authenticated", USER_A, async () => {
    await denies("update public.profiles set tier = 'pro' where id = $1", "42501", [USER_A]);
    await denies("update public.profiles set tier = 'pro'", "42501");
    await denies("update public.profiles set stripe_customer_id = 'cus_x' where id = $1", "42501", [USER_A]);
  });
  ok((await tierOf(USER_A)) === "free", "tier changed");
});

await check("a user cannot insert or delete profiles (42501)", async () => {
  await asRole("authenticated", USER_A, async () => {
    await denies("insert into public.profiles (id, tier) values (gen_random_uuid(), 'pro')", "42501");
    await denies("delete from public.profiles where id = $1", "42501", [USER_A]);
    await denies("delete from public.profiles", "42501");
  });
  ok((await rows("select id from public.profiles")).length === 3, "profile count changed");
});

await check("a user cannot read stripe_customer_id, by name or with * (42501)", async () => {
  await asRole("authenticated", USER_A, async () => {
    await denies("select stripe_customer_id from public.profiles", "42501");
    await denies("select * from public.profiles", "42501");
    await denies("select id from public.profiles where stripe_customer_id is not null", "42501");
    ok((await rows("select id, tier from public.profiles")).length === 1, "id, tier is not readable");
  });
});

await check("anon reads and writes nothing", async () => {
  await asRole("anon", null, async () => {
    let readRows = null;
    try {
      readRows = (await db.query("select id from public.profiles")).rows;
    } catch (error) {
      ok(error.code === "42501", `anon select failed with ${error.code}, not 42501`);
    }
    ok(readRows === null || readRows.length === 0, "anon can read rows");
    await denies("insert into public.profiles (id) values (gen_random_uuid())", "42501");
    await denies("update public.profiles set tier = 'pro'", "42501");
    await denies("delete from public.profiles", "42501");
  });
});

await check("client roles hold no table privilege beyond SELECT on (id, tier)", async () => {
  const [priv] = await rows(`
    select
      has_table_privilege('authenticated', 'public.profiles', 'select') as auth_table_select,
      has_table_privilege('authenticated', 'public.profiles', 'insert,update,delete,truncate,references,trigger') as auth_table_write,
      has_column_privilege('authenticated', 'public.profiles', 'id', 'select') as auth_id,
      has_column_privilege('authenticated', 'public.profiles', 'tier', 'select') as auth_tier,
      has_column_privilege('authenticated', 'public.profiles', 'stripe_customer_id', 'select') as auth_stripe,
      has_column_privilege('authenticated', 'public.profiles', 'tier', 'update') as auth_tier_update,
      has_table_privilege('anon', 'public.profiles', 'select,insert,update,delete,truncate,references,trigger') as anon_any,
      has_column_privilege('anon', 'public.profiles', 'tier', 'select') as anon_tier
  `);
  ok(priv.auth_id && priv.auth_tier, "authenticated cannot read id, tier");
  ok(!priv.auth_table_select && !priv.auth_table_write && !priv.auth_stripe && !priv.auth_tier_update, "authenticated has more than column SELECT on id, tier");
  ok(!priv.anon_any && !priv.anon_tier, "anon has a privilege");
});

await check("handle_new_user() cannot be executed by anon or authenticated (42501)", async () => {
  for (const role of ["anon", "authenticated"]) {
    await asRole(role, null, async () => {
      await denies("select public.handle_new_user()", "42501");
    });
  }
});

await check("handle_new_user() is SECURITY DEFINER with an empty search_path", async () => {
  const [fn] = await rows("select prosecdef, proconfig from pg_proc where oid = 'public.handle_new_user()'::regprocedure");
  ok(fn.prosecdef === true, "not security definer");
  ok(Array.isArray(fn.proconfig) && fn.proconfig.some((c) => /^search_path=("")?$/.test(c)), `proconfig is ${JSON.stringify(fn.proconfig)}`);
});

await check("service_role sees every row and can set tier and stripe_customer_id", async () => {
  await asRole("service_role", null, async () => {
    ok((await rows("select id from public.profiles")).length === 3, "service_role does not see all rows");
    const res = await db.query("update public.profiles set tier = 'pro', stripe_customer_id = 'cus_A' where id = $1", [USER_A]);
    ok(res.affectedRows === 1, "update did not affect one row");
    const [row] = await rows("select tier, stripe_customer_id from public.profiles where id = $1", [USER_A]);
    ok(row.tier === "pro" && row.stripe_customer_id === "cus_A", "the update is not visible");
  });
});

await check("tier is constrained to free or pro (23514), and stripe_customer_id is unique (23505)", async () => {
  await asRole("service_role", null, async () => {
    await denies("update public.profiles set tier = 'gold' where id = $1", "23514", [USER_A]);
    await denies("update public.profiles set stripe_customer_id = 'cus_A' where id = $1", "23505", [USER_B]);
  });
});

await check("user A now reads their new tier through their own token (id, tier)", async () => {
  await asRole("authenticated", USER_A, async () => {
    const [row] = await rows("select id, tier from public.profiles");
    ok(row.tier === "pro", "A does not see the tier the Worker wrote");
  });
});

// ---------------------------------------------------------------------------
// 0002_referrals.sql: referral_code on profiles, and the referrals table.
// ---------------------------------------------------------------------------

await check("every profile got a default 8-character referral_code, and it is unique (23505)", async () => {
  const codes = await rows("select id, referral_code from public.profiles");
  for (const c of codes) ok(typeof c.referral_code === "string" && c.referral_code.length === 8, `referral_code for ${c.id} is ${JSON.stringify(c.referral_code)}`);
  ok(new Set(codes.map((c) => c.referral_code)).size === codes.length, "two profiles share a referral_code");
  await asRole("service_role", null, async () => {
    const codeA = (await rows("select referral_code from public.profiles where id = $1", [USER_A]))[0].referral_code;
    await denies("update public.profiles set referral_code = $1 where id = $2", "23505", [codeA, USER_B]);
  });
});

await check("referrals: no_self_referral check constraint (23514) rejects referrer_id = referee_id", async () => {
  await asRole("service_role", null, async () => {
    await denies("insert into public.referrals (referrer_id, referee_id, code) values ($1, $1, 'selfcode')", "23514", [USER_A]);
  });
});

await check("referrals: unique_referee constraint (23505) rejects a second row for the same referee", async () => {
  await asRole("service_role", null, async () => {
    await db.query("insert into public.referrals (referrer_id, referee_id, code) values ($1, $2, 'abc12345')", [USER_A, USER_B]);
    // A different referrer, same referee: isolates unique_referee from a plain duplicate-row rejection.
    await denies("insert into public.referrals (referrer_id, referee_id, code) values ($1, $2, 'zzz99999')", "23505", [LEGACY, USER_B]);
  });
});

await check("referrals: RLS is enabled and both anon and authenticated see zero rows (fail-closed), despite the table GRANT", async () => {
  const [cls] = await rows("select relrowsecurity from pg_class where oid = 'public.referrals'::regclass");
  ok(cls.relrowsecurity === true, "RLS is not enabled on public.referrals");
  // `grant select on public.referrals to authenticated` (0002_referrals.sql) exists, but no policy
  // does: RLS with zero policies denies every row to every non-bypassrls role regardless of grants,
  // so today the grant is dead code — nobody, not even the referee or referrer, can read their own
  // referral row via the client. Whether to add a policy (and what it should allow) is a product
  // decision, not one this check makes for them; it only pins the current (fail-closed) behaviour
  // so a future migration cannot loosen it by accident.
  const policies = await rows("select 1 from pg_policies where schemaname = 'public' and tablename = 'referrals'");
  ok(policies.length === 0, `expected no policies on public.referrals (the grant is currently dead code), found ${policies.length}`);
  // authenticated has a table-level GRANT SELECT (line 34 of the migration) but RLS with no
  // policy still returns zero rows. anon was never granted SELECT at all, so it fails at the
  // privilege check (42501) before RLS is even reached — the same shape as profiles' anon check.
  await asRole("authenticated", USER_A, async () => {
    ok((await rows("select id from public.referrals")).length === 0, "authenticated can see referral rows with no policy");
  });
  await asRole("anon", null, async () => {
    let readRows = null;
    try {
      readRows = (await db.query("select id from public.referrals")).rows;
    } catch (error) {
      ok(error.code === "42501", `anon select failed with ${error.code}, not 42501`);
    }
    ok(readRows === null || readRows.length === 0, "anon can read referral rows");
  });
});

await check("deleting a user removes their profile (on delete cascade)", async () => {
  await db.query("delete from auth.users where id = $1", [USER_B]);
  ok((await tierOf(USER_B)) === undefined, "profile survived its user");
});

await check("the migration runs a second time without error and changes nothing", async () => {
  await applyMigrations();
  ok((await tierOf(USER_A)) === "pro", "a re-run reset a paid tier");
  ok((await rows("select id from public.profiles")).length === 2, "profile count changed on re-run");
  const policies = await rows("select 1 from pg_policies where schemaname = 'public' and tablename = 'profiles'");
  ok(policies.length === 1, `expected 1 policy after re-run, found ${policies.length}`);
  const triggers = await rows("select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and not tgisinternal and tgname = 'on_auth_user_created'");
  ok(triggers.length === 1, `expected 1 trigger after re-run, found ${triggers.length}`);
});

await check("the lock-down still holds after the re-run", assertLockedDown);

await check("the trigger still creates a free profile after the re-run", async () => {
  await db.query("insert into auth.users (id, email) values ($1, 'c@example.com')", [USER_C]);
  ok((await tierOf(USER_C)) === "free", "no free profile for the new user");
});

process.stdout.write(`\n${passed} passed, ${failed} failed (${migrationFiles.join(", ")})\n`);
process.exit(failed === 0 ? 0 : 1);
