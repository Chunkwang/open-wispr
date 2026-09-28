# open-wispr-proxy

Metered API Proxy — TRD Section 3.3. The only path from the client to the Claude API. Authenticates the request (Supabase JWT), checks the user's tier and quota, calls Claude, and updates tier on Stripe webhook events. No user content is stored — only usage counts for billing.

## Endpoints

- `POST /v1/rewrite` — body `{ "transcript": string }`, header `Authorization: Bearer <supabase session token>`. Returns `200 { "rewritten": string }`.
  Errors are always JSON `{ "error": string }`. Checks run in this order, and every check before the provider call is enforced on the server:

  | Status | `error` | When |
  |---|---|---|
  | 401 | `unauthorized` | Missing, malformed, tampered or expired token; wrong algorithm for the configured mode (see "Token verification modes"); a `kid` that is not in the JWKS (jwks mode); `aud` is neither `authenticated` nor a list that includes it; `iss` is not `${SUPABASE_URL}/auth/v1`; no `exp` claim; `sub` is not a UUID. Old dev tokens minted before the `iss` requirement land here too: re-mint with `npm run dev:token`. |
  | 413 | `transcript_too_long` | Two caps, both enforced: the request body is over 64 KB (65,536 bytes is accepted, 65,537 is not; checked from `Content-Length`, or while streaming when there is none), or `transcript` is over 16,000 characters, counted in Unicode code points (an emoji is one character). Sixteen thousand emoji is about 64,017 bytes, so it fits both caps. Nothing is looked up, counted or sent to the provider. |
  | 400 | `invalid request body` | Not valid UTF-8, not valid JSON, or not a JSON object. |
  | 400 | `missing transcript` | `transcript` is absent, empty, whitespace-only, or not a string. |
  | 402 | `rewrite requires the Pro tier` | The user is Free, or has no profile row. |
  | 429 | `minute_limit` or `monthly_limit` | Quota used up (Pro: 5 per minute, 3000 per month; placeholders). A request counts once it is admitted, and is not refunded if the provider then fails (502): the quota counts attempts. |
  | 502 | `rewrite failed` | The provider failed, was not answered within 90 s, or did not finish normally. Only `end_turn` and `stop_sequence` with non-empty text are accepted; `max_tokens`, `refusal`, `pause_turn`, `tool_use`, unknown reasons and empty text are all 502, so a cut-off or refused dictation is never returned as if it were complete. One attempt only, no retries. |
  | 503 | `service_unavailable` | The tier lookup (Supabase, 3 s deadline) or the quota store (Durable Object, 3 s deadline) failed, was unreachable or hung; or, in jwks mode, the signing keys could not be fetched (JWKS unreachable, non-200, a redirect, over 3 s, not JSON, not a key set, or a key set with no keys). Not a statement about the user's tier or token: the client should treat it as a temporary outage, keep the session and retry later (never refresh or sign out on it). No upstream details are included or logged. |
  | 500 | `misconfigured` | `JWT_VERIFY_MODE` is not exactly `hs256` or `jwks` (any host); in hs256 mode, off loopback, the Worker holds a `SUPABASE_JWT_SECRET` that is the published example, starts with `local-dev-`, is under 32 characters or is missing; in jwks mode, off loopback, the JWKS URL is not https on `SUPABASE_URL`'s origin (or has credentials). Fixed body on purpose; the cause is not stated. Fix the configuration. |
  | 500 | `internal_error` | Anything unexpected. Fixed body, no stack trace. |

  Order of checks: config guards, authentication, body size and validation, tier, quota, provider. Malformed, oversized and unauthenticated requests never reach the tier lookup and never consume quota. Unauthenticated requests are answered 401 without their body being read.
- `GET /v1/me` — header `Authorization: Bearer <supabase session token>`. Returns `200 { "tier": "free"|"pro", "remainingThisMonth": number }`. `remainingThisMonth` is a live read of the user's own rewrite quota counter (`QuotaCounter.remaining`, via `peekQuota` in `rateLimit.ts`) — it changes the instant a rewrite is admitted, and reading it never itself consumes any quota. `401 unauthorized`, `429 minute_limit`/`monthly_limit` (own per-user "me" quota bucket, not shared with any other kind — generous, 60/min · 100,000/month, well above the client's "poll for up to two minutes after checkout" use case, checked before the tier lookup or the quota peek so an uncapped caller cannot hammer either for free), `500 misconfigured` (same JWT guard as every authenticated route), `503 service_unavailable` (the "me" quota check, the tier lookup, or the quota peek failed or hung, 3 s deadline on each).
- `POST /v1/billing/checkout` — authenticated, no request body. Short-circuits with `409 { "error": "already_pro" }` if the caller's tier is already Pro (no Stripe call made) — see the comment in `handleBillingCheckout` for what this does and does not close. Otherwise creates (or reuses) the user's Stripe customer, saves `stripe_customer_id` to their profile (best-effort: a failed save is logged but does not block the checkout, since portal lookups are the only thing that depend on it), and creates a Checkout Session for `STRIPE_PRICE_ID` with `subscription_data.metadata.supabase_user_id` set — the exact field the webhook reads. Returns `200 { "url": string }`. Reachable by Free users on purpose: it's how they become Pro. `401 unauthorized`, `409 already_pro`, `429 minute_limit`/`monthly_limit` (own per-user "billing" quota bucket, shared with `/v1/billing/portal`, 5/min · 30/month — session creation is a real, metered call against Stripe, mock or not), `500 misconfigured` (JWT guard, or `STRIPE_WEBHOOK_SECRET`/`STRIPE_SECRET_KEY`/`STRIPE_PRICE_ID`/`SUPABASE_SERVICE_ROLE_KEY` still a `.dev.vars.example` placeholder off loopback), `502 checkout_failed` (Stripe rejected the session, or returned no URL), `503 service_unavailable` (the tier lookup, the Supabase profile lookup, or the Stripe customer call failed).
- `POST /v1/billing/portal` — authenticated, no request body. Looks up `stripe_customer_id` and creates a Stripe billing portal Session. Returns `200 { "url": string }`. `401 unauthorized`, `404 no_customer` (no `stripe_customer_id` on file yet — call checkout first), `429`/`500`/`503` as above, `502 portal_failed` (Stripe rejected the session).
- `POST /v1/stripe/webhook` — Stripe webhook receiver, signature verified from the raw body (`stripe.webhooks.constructEventAsync`, `STRIPE_WEBHOOK_SECRET`). `400 missing signature`/`invalid signature`. Handles `customer.subscription.created`/`updated`/`deleted` identically — **tier derives from the subscription's current `status` on the event, never from the event's `type`**, so a duplicated or out-of-order delivery (Stripe makes no ordering guarantee) is idempotent: replaying the same event has the same effect as applying it once. `active`/`trialing` → `pro`, `past_due`/`canceled` → `free` (the `past_due` case is a product decision CLAUDE.md flags as needing sign-off, not something this proxy defaults silently — see "Still placeholders" below). Requires the subscription's `metadata.supabase_user_id` (set by `/v1/billing/checkout`); if it is absent, answers `200` (retrying cannot fix a permanently missing field) but logs `stripe webhook: subscription event missing metadata.supabase_user_id, ignoring` so the anomaly is visible rather than silent. A **failed Supabase write answers a genuine 5xx**, not 200 — Stripe only retries a non-2xx response, and 200 here would leave a paying customer stuck on Free with no second chance. Off loopback it answers `500 {"error":"misconfigured"}` while `STRIPE_WEBHOOK_SECRET`, `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID` or `SUPABASE_SERVICE_ROLE_KEY` is still one of the `.dev.vars.example` placeholders (same guard as `/v1/billing/*`, `hostGuard.ts`'s `placeholderStripeConfigOffLoopback`).

## One-time setup

1. `npm install`
2. Nothing to create for quota: the `QUOTA` Durable Object binding and its migration (`new_sqlite_classes = ["QuotaCounter"]`) are in `wrangler.toml` and are applied by `npm run deploy`.
3. Set `SUPABASE_URL` and `STRIPE_PRICE_ID` (the one Pro plan's Stripe Price id) in `wrangler.toml`'s `[vars]`, `JWT_VERIFY_MODE` (`hs256` or `jwks`, see "Token verification modes") to match the project's JWT signing keys, and once a real domain exists, `BILLING_SUCCESS_URL`/`BILLING_CANCEL_URL`/`BILLING_PORTAL_RETURN_URL`. Never set `STRIPE_API_BASE_URL` here — it is a `.dev.vars`-only override for the local mock Stripe, and the Worker refuses to honor it off loopback regardless.
4. Set secrets (never committed; `SUPABASE_JWT_SECRET` only in hs256 mode):
   ```
   npx wrangler secret put SUPABASE_JWT_SECRET
   npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
   npx wrangler secret put ANTHROPIC_API_KEY
   npx wrangler secret put STRIPE_SECRET_KEY
   npx wrangler secret put STRIPE_WEBHOOK_SECRET
   ```
5. In Supabase, apply `../supabase/migrations/0001_profiles.sql` (SQL editor, or `supabase db push`). See "Database migration" below.
6. `npm run dev` to run locally, `npm run deploy` to ship.

## Local development

No accounts or real keys are needed to run the whole rewrite path locally: the Worker under `wrangler dev`, a mock Supabase, and a mock LLM. There is no auth bypass in the Worker: it verifies a real HS256 JWT (audience `authenticated`, issuer `${SUPABASE_URL}/auth/v1`), and you mint one with your own local secret.

1. `cp .dev.vars.example .dev.vars` (gitignored; placeholder values only). `SUPABASE_JWT_SECRET` must start with `local-dev-`: the token script refuses anything else, so a real project secret can't be used by accident. (The Worker in turn refuses such a secret off loopback.)
2. In `.dev.vars`, uncomment `LLM_PROVIDER=mock`. Without it the Worker calls the real Claude API, which fails with the placeholder key.
3. Terminal 1: `npm run dev:mock` starts the mock Supabase on `http://127.0.0.1:54321` (`PORT=...` to change it).
4. Terminal 2: `npm run dev:mock:stripe` starts the mock Stripe on `http://127.0.0.1:54323` — only needed to exercise `/v1/billing/*` or the webhook; skip it if you're only calling `/v1/rewrite`. `STRIPE_API_BASE_URL` in `.dev.vars.example` already points at this port.
5. Terminal 3: `npm run dev` starts `wrangler dev` on `http://127.0.0.1:8787`.
6. Terminal 4: mint a token and call the proxy:
   ```
   curl -X POST http://127.0.0.1:8787/v1/rewrite \
     -H "Authorization: Bearer $(npm run -s dev:token)" \
     -H "Content-Type: application/json" \
     -d '{"transcript":"um so like send it tomorrow"}'
   # {"rewritten":"Send it tomorrow."}
   ```

Use exactly `127.0.0.1` or `localhost` in the URL (not `0.0.0.0`, `[::1]`, `127.0.0.2` or `localhost.`: those count as deployed). The mock LLM is not used on any other hostname, and on any other hostname the Worker refuses a local-dev JWT secret (500 `misconfigured`).

Known `wrangler dev` artifact: if a client sends an oversized body with `Transfer-Encoding: chunked` (no `Content-Length`), the Worker answers 413 correctly, but the very next request on the dev server can fail once with `500 Network connection lost` (raised by miniflare's dev proxy, not by this Worker; the request after that succeeds). Real clients send `Content-Length`, which is refused without reading the body, and this has not been seen outside `wrangler dev`. Not investigated further.

### Mock Supabase (`scripts/mock-supabase.mjs`)

In-memory, `node:http` and `node:crypto` only, bound to 127.0.0.1. Design: `docs/auth-design.md` section 2. `PORT=0` picks a free port and the start-up line prints the real one. State resets when the mock restarts, or with `POST /__dev/reset`. The `.dev.vars` reader is shared with `mint-dev-token.mjs` (`scripts/lib/dev-vars.mjs`).

**PostgREST (what the Worker calls).**

- `GET /rest/v1/profiles?id=eq.<uuid>&select=tier` returns `[{"tier":"pro"}]`.
- `PATCH /rest/v1/profiles?id=eq.<uuid>` with `{"tier":"free"|"pro"}` sets that user's tier (the Stripe webhook path). Answers 204 for `Prefer: return=minimal`.
- Requests without `apikey` and `Authorization` headers get 401. Users never PATCHed get `MOCK_TIER` (default `pro`): `MOCK_TIER=free npm run dev:mock` makes `/v1/rewrite` answer 402.

**GoTrue email-code sign-in (what the macOS client calls).** Every `/auth/v1/*` route needs an `apikey` header, else 401 `{"message":"No API key found in request"}`. Errors are `{"code":<http>,"error_code":"<x>","msg":"<text>"}`; clients classify by status and `error_code`, never by message text.

| Route | Request | Success | Errors |
|---|---|---|---|
| `POST /auth/v1/otp` | `{"email","create_user":true}` | 200 `{}`; a 6-digit code (or `MOCK_FIXED_CODE`) is issued and replaces any earlier one | 400 `validation_failed` (invalid email); 429 `over_email_send_rate_limit` with `Retry-After` (a second send within `MOCK_OTP_RESEND_SECONDS`, default 60) |
| `POST /auth/v1/verify` | `{"type":"email","email","token"}` | 200 session (below); the code is single use | 403 `otp_expired` for a wrong, expired, used or never-issued code (deliberately indistinguishable, like real GoTrue); 429 `over_request_rate_limit` with `Retry-After` after `MOCK_MAX_VERIFY_ATTEMPTS` (5) wrong tries for one email, for `MOCK_LOCKOUT_SECONDS` (60), even for the right code; 400 `validation_failed` for another `type` or a bad email; 422 `validation_failed` for a token that is not 6 to 10 digits |
| `POST /auth/v1/token?grant_type=refresh_token` | `{"refresh_token"}` | 200 session with a rotated refresh token (same `session_id`) | 400 `refresh_token_not_found` (unknown, or its session was signed out or revoked); 400 `refresh_token_already_used` (a rotated-out token was presented: reuse detection, and the whole session dies, so its newest token then reads as already used); 400 `validation_failed` (other grant type, missing token) |
| `POST /auth/v1/logout?scope=local\|global\|others` | `Authorization: Bearer <access>` | 204; that session's (or the user's other, or all) refresh tokens are gone. Idempotent | 401 `bad_jwt` (missing, malformed, wrong signature, expired, wrong issuer or audience); 400 `validation_failed` (unknown scope) |

Session JSON: `{"access_token","token_type":"bearer","expires_in","expires_at","refresh_token","user":{"id","aud":"authenticated","role":"authenticated","email"}}`. The refresh token is 12 opaque base64url characters. The access token is an HS256 JWT signed with `SUPABASE_JWT_SECRET` with `aud=authenticated`, `iss=${SUPABASE_URL}/auth/v1`, `sub` = UUID v5 of the lowercased, trimmed email (RFC 4122 DNS namespace), `iat`, `exp`, `email`, `role`, `session_id`, `jti`, `app_metadata`, `user_metadata`; the Worker accepts it in `hs256` mode and the test suite proves it with `jose` and the same options as `src/auth.ts`. The mock exits at start-up unless the secret starts with `local-dev-`.

Differences from real Supabase (all VERIFY-ON-DAY-16): the mock has no refresh reuse window (real GoTrue tolerates a re-used token for about 10 s, so the client must still serialise refreshes); whether real Supabase sends `Retry-After` on a 429; real error codes and limits for `verify`; `create_user` is ignored; only the `refresh_token` grant exists.

**Dev-only routes.** They answer only when the `Host` header is exactly `127.0.0.1` or `localhost` (any port); every other Host gets 404, so a web page on another origin cannot read codes.

- `GET /__dev/last-code?email=<e>` returns `{"code":"123456"}` (the latest code for that email, even after use) or 404.
- `POST /__dev/fail` `{"route":"otp|verify|token|logout|profiles|any","mode":"503|429|500|drop|hang","times":n}` makes the next `n` (default 1) matching requests fail: 503/500 answer with that status, 429 with `Retry-After: 30`, `drop` closes the connection, `hang` never answers.
- `POST /__dev/revoke` `{"email"}` deletes that user's sessions and refresh tokens; already-issued access tokens stay valid until `exp`.
- `POST /__dev/reset` forgets everything.

**Environment knobs.** `PORT`, `SUPABASE_URL` (issuer; env, else `.dev.vars`, else `http://127.0.0.1:<port>`), `SUPABASE_JWT_SECRET` (env, else `.dev.vars`), `MOCK_TIER`, `MOCK_FAIL` (`503` answers every non-dev request with 503; `drop` closes the connection), `MOCK_OTP_RESEND_SECONDS` (60, 0 disables), `MOCK_OTP_TTL_SECONDS` (600), `MOCK_FIXED_CODE`, `MOCK_MAX_VERIFY_ATTEMPTS` (5), `MOCK_LOCKOUT_SECONDS` (60), `MOCK_ACCESS_TTL_SECONDS` (3600; use 60 to exercise refresh quickly), `MOCK_JWT_MODE` (`hs256` default; `es256` signs with a P-256 key generated at start-up, kid `mock-es256-1`, and serves it at `GET /auth/v1/.well-known/jwks.json` so the Worker can run with `JWT_VERIFY_MODE=jwks`; in hs256 mode that endpoint serves `{"keys":[]}`, like a legacy project; `mint-dev-token` only mints HS256).

**Logging.** Each request logs its method and path only (no query string, headers or bodies). The one exception is `mock-supabase: code for <email> is <code>` on stdout when a code is issued: this is how a developer reads the code, it exists only in the mock, and nothing else (no token, secret or key) is ever printed.

Tests: `npm run test:mock` (`scripts/mock-supabase.test.mjs`, node's built-in runner) starts the real script on port 0 and covers every row above. CI runs it in the `backend` job.

### Mock Stripe (`scripts/mock-stripe.mjs`)

In-memory, `node:http` and `node:crypto` only, bound to 127.0.0.1. Start with `npm run dev:mock:stripe` (default port 54323). `.dev.vars.example` sets `STRIPE_API_BASE_URL=http://127.0.0.1:54323` uncommented by default — like `SUPABASE_URL`, this is always-on dev infrastructure, not a per-call opt-in — so with the mock running, `wrangler dev`'s Stripe client (`src/stripeClient.ts`) talks to it instead of `api.stripe.com`, and never does off loopback even if that line were copied into deployed config.

**Real Stripe API surface it serves** (`application/x-www-form-urlencoded` bodies with bracket nesting, exactly what the `stripe` npm SDK sends, not JSON):

- `POST /v1/customers` — `metadata[supabase_user_id]` → `{"id":"cus_...","object":"customer","metadata":{...}}`
- `POST /v1/checkout/sessions` — `customer`, `line_items[0][price]`, `subscription_data[metadata][supabase_user_id]`, `success_url`, `cancel_url` → a session with a `url`
- `POST /v1/billing_portal/sessions` — `customer`, `return_url` → a session with a `url`

**Completing a checkout end to end**, without a Stripe account: `POST /v1/billing/checkout` against the running Worker returns a `url` containing a `session=cs_...` id; `POST http://127.0.0.1:54323/__dev/complete-checkout {"session_id":"cs_..."}` creates a subscription from that session's stored metadata, **signs a real `customer.subscription.created` event with the shared `STRIPE_WEBHOOK_SECRET`** (the same HMAC-SHA256 timestamped scheme `stripe.webhooks.constructEventAsync` verifies — `t=<unix seconds>,v1=<hex HMAC of "<t>.<payload>">`), and POSTs it straight to the Worker's `/v1/stripe/webhook`, exactly as a real Stripe delivery would. The response includes `webhook_status`/`webhook_body`, so `GET /v1/me` right after should show `tier: "pro"`.

`POST /__dev/fire-webhook {"type","supabase_user_id","status"?}` does the same signing and firing directly (no Checkout Session needed), for exercising a status like `past_due`/`canceled` or an event type on its own. `POST /__dev/fail {"route":"customers"|"checkout_sessions"|"portal_sessions"|"any","mode":"503"|"500"|"drop"|"hang","times":n}` and `POST /__dev/reset` follow the same pattern as the mock Supabase's failure injection.

Verified standalone (spawned directly with an echo server standing in for the Worker, not via `wrangler dev`): the mock's signed webhook requests are accepted by the real `stripe` npm package's own `webhooks.constructEventAsync` verifier — the same one `src/stripeWebhook.ts` runs — and rejected with the wrong secret, confirming the signing scheme is correct, not just internally consistent.

### Mock LLM (`src/llmProvider.ts`)

Deterministic and text-only: it strips fillers (um, uh, "you know", a leading "so", "like" used as a filler), collapses spaces, fixes a lone lowercase "i", capitalises, and adds a final full stop. It never follows instructions inside the transcript.

It is used only when `LLM_PROVIDER=mock` is set AND the request hostname is `127.0.0.1` or `localhost` (`chooseProvider`). Any other case falls back to the real Claude path. `LLM_PROVIDER` must never appear in `wrangler.toml` or as a Wrangler secret.

### Tokens

`npm run dev:token -- [user-id] [--ttl <seconds>]` prints only the token. `user-id` must be a UUID (the Worker rejects any other subject). It defaults to a fixed dev user id and a 1 hour lifetime, and takes the secret from the `SUPABASE_JWT_SECRET` env var, else `.dev.vars`. It exits non-zero with a message if neither is set, and refuses any secret that does not start with `local-dev-`. The token's issuer is `${SUPABASE_URL}/auth/v1` with `SUPABASE_URL` from the env var, else `.dev.vars`, else `http://127.0.0.1:54321`; keep it equal to the Worker's `SUPABASE_URL`, or the Worker answers 401.

Use a different user id to get a fresh quota (Pro is 5 requests per minute per user). Quota state lives in the local Durable Object storage under `.wrangler/`; delete that folder to reset everyone.

## Token verification modes (`src/auth.ts`)

`JWT_VERIFY_MODE` (a `[vars]` entry in `wrangler.toml`, default `hs256` when unset) chooses how the Supabase access token is verified. It comes only from configuration: nothing in the token can select the mode, and `jku`, `x5u` and embedded `jwk` headers are never followed. Any other value (including a different case, empty or a typo) is a 500 `misconfigured` on every host: the Worker never falls back to another mode.

| | `hs256` (default) | `jwks` |
|---|---|---|
| Algorithms accepted | `HS256` only | `ES256`, `RS256` only |
| Key | shared `SUPABASE_JWT_SECRET` | the project's JWKS, matched by `kid` |
| Secret needed | yes (guarded off loopback) | no: `SUPABASE_JWT_SECRET` is not read and its guard does not apply |
| Network | none | one GET of the JWKS, then cached |

`none` and every other algorithm are refused in both modes, and an algorithm from the other mode is refused too (so an HS256 token "signed" with the public key bytes cannot pass in jwks mode, and an ES256 token is 401 in hs256 mode). `iss`, `aud`, `exp` and a UUID `sub` are enforced in both.

jwks mode details:

- URL: `SUPABASE_JWKS_URL` if set, else `${SUPABASE_URL}/auth/v1/.well-known/jwks.json`. Off loopback it must be https on the same origin as `SUPABASE_URL` with no credentials, else 500 `misconfigured`; on loopback (local dev) plain http and any host are allowed.
- Fetch: `redirect: manual` (a redirect is a failure), 3 s timeout, response must be 200 JSON. Key sets are cached per URL for the life of the isolate: 10 minutes (`cacheMaxAge`), and an unknown `kid` triggers at most one refetch per 30 s (`cooldownDuration`). A failed fetch is not cached, so the next request retries. While the cache is fresh, a JWKS outage does not affect requests. Once it is older than 10 minutes and the refetch fails, requests get 503 (jose does not serve a stale set).
- Failure mapping: the key source failing (fetch error, timeout, non-200, redirect, non-JSON, not a key set, a key that cannot be imported, or a key set with no keys at all, which is what a legacy-HS256 project serves) is a 503 `service_unavailable` with the same fixed body and log kind (`tier_lookup_failed`) as a tier outage: the token was not shown to be bad, and a 401 would push the client into refresh and sign-out. An unknown `kid`, an ambiguous key match, a bad signature or a disallowed algorithm is a 401: input the caller controls can never cause a 503 while the JWKS is healthy.
- A token that is malformed, or uses an algorithm not allowed in the mode, is refused before any key is fetched.

Day 16: check which signing keys the real project uses (Supabase dashboard, Project Settings, JWT Keys), set `JWT_VERIFY_MODE` accordingly, and run one real user token through it. If the project is on asymmetric keys, jwks mode means the Worker holds no shared secret at all.

## Database migration (`../supabase/migrations/0001_profiles.sql`)

Creates `public.profiles(id, tier, stripe_customer_id, created_at)`, one row per user, filled by a trigger on `auth.users` (a `security definer` function with an empty `search_path`) and backfilled for existing users. No email is stored there. Re-runnable.

Who can do what: the Worker uses the service-role key (bypasses RLS) to read the tier and, from the Stripe webhook, write `tier` and `stripe_customer_id`. A signed-in user can read only their own `id` and `tier` (RLS policy plus a column-level grant that hides `stripe_customer_id`) and can write nothing. Supabase grants ALL on new public tables to `anon` and `authenticated` by default, so the migration's explicit `revoke all ... from anon, authenticated` is the real protection; RLS with no write policy is the second layer.

Offline check: `backend/supabase/scripts/check-migration.mjs` runs the migration twice in PGlite (WASM Postgres) with a harness that imitates Supabase's roles, `auth.uid()` and default privileges, and asserts the rules above (20 assertions). PGlite is not a project dependency:

```
mkdir -p /tmp/pglite && cd /tmp/pglite && npm init -y && npm install @electric-sql/pglite
PGLITE_DIR=/tmp/pglite node backend/supabase/scripts/check-migration.mjs    # from the repo root
```

Exit 0 all passed, 1 an assertion failed, 2 PGlite not found (nothing checked). This is not proof about the real project: the harness reproduces Supabase's behaviour from memory. On Day 16, apply the migration to the real project and repeat the key checks with a real user token (a user cannot PATCH their own `tier`, cannot read `stripe_customer_id`, sees only their own row; `anon` sees nothing).

## Quota (`src/quotaCounter.ts`, `src/rateLimit.ts`)

Per-user quota is a Durable Object, one `QuotaCounter` per user id (`QUOTA.idFromName(userId)`, or `${kind}:${userId}` for every kind but `rewrite` — see `QuotaKind` in `src/types.ts`: `rewrite`, `edit`, `referral`, `events`, `billing`, `me` each get their own counter, so none can spend another's allowance). Its method `consume(limits, nowMs)` checks the per-minute and per-month windows and increments both inside one synchronous storage transaction, so parallel requests cannot interleave between the read and the write (the old KV read-then-write let 30 parallel requests through a limit of 5). A denied request is not counted. Its read-only counterpart `remaining(limits, nowMs)` (used by `GET /v1/me` via `peekQuota`) reports the same windows without consuming any of them. The object stores counts only (one row per active window: kind, window, count), never content and not even the user id, and deletes expired windows on every write. The Worker computes the limits from each kind's table and passes `nowMs`; windows are the UTC minute and UTC month. The Worker waits at most 3 s for the Durable Object; a failure, timeout or unreachable object is a 503 `service_unavailable`.

## Tests

`npm test` runs vitest inside real workerd (`@cloudflare/vitest-pool-workers`, config in `vitest.config.mts`), and `npm run typecheck` covers `src/` and `test/`. `npm run test:mock` runs the mock Supabase's own contract tests (node's built-in runner). CI runs all three in the `backend` job.

One config note: jose's remote key set rejects an inner promise that its async wrapper adopts a tick later, which the workers test pool reports as "Unhandled Rejection" even though `auth.ts` handles it (the tests assert the 401). `vitest.config.mts` ignores exactly `ERR_JWKS_NO_MATCHING_KEY` and `ERR_JWKS_MULTIPLE_MATCHING_KEYS` unhandled errors; any other unhandled error still fails the run.

- Every request goes through the Worker's `fetch` handler (`test/helpers.ts` `call()`), never through internals such as `rateLimit.ts`. Outbound calls (Supabase, Anthropic) are answered by a fetch mock in `test/helpers.ts`; any other outbound URL throws, so a test cannot reach the network.
- Bindings are fixed fake values set in `vitest.config.mts`, and `LLM_PROVIDER` is off unless a test sets it, so the run does not depend on your `.dev.vars` (which may enable the mock LLM). The Supabase and Anthropic keys there are canary strings that the logging tests search for.
- Tokens are minted per test with `jose` and a `local-dev-` secret. Each test uses a fresh user id, so quotas never collide.
- Test files: `test/jwt-modes.test.ts` (hs256 and jwks modes with ES256 and RS256 keys generated by `jose`, the JWKS served through the fetch mock: algorithm allow-lists and confusion, unknown `kid`, `jku` ignored, caching, rotation and cooldown, every JWKS failure as 503, JWKS URL guard, invalid mode), `test/rewrite.test.ts` (auth, tier, quota basics, body and size validation, mock LLM guard, Claude path, outages), `test/hardening.test.ts` (Claude finish reasons and single attempt, deployed-host guard, loopback set, token claims, URL normalisation, size and code-point caps), `test/quota.test.ts` (real Durable Object: parallel-burst atomicity, per-user isolation, window resets, month limit, storage contents, 503 on failure or hang), `test/logging.test.ts` (success and every failure path, with console spies, asserting nothing sensitive is ever logged), `test/stripe-webhook.test.ts` (signature verification incl. a tampered payload, the full status matrix, missing metadata as a logged 200 no-op, a failed Supabase write as a real 5xx, idempotent replay and out-of-order delivery), `test/billing.test.ts` (checkout/portal customer creation and reuse, the best-effort `stripe_customer_id` save, the already-Pro short-circuit, every failure path, the shared per-user rate limit) and `test/me.test.ts` (tier and live remaining-quota reporting, that reading it never consumes quota, its own per-user rate limit, every failure path).
- Quota tests use a real `QuotaCounter` in workerd. Tests that send several requests freeze only `Date` (`freezeClock()`) so no minute boundary can fall inside a test. Only `brokenQuotaEnv()` and `hangingQuotaEnv()` in `test/helpers.ts` name the quota binding.
- `test/helpers.ts`'s `installUpstream()` mocks `https://api.stripe.com` the same way it mocks Supabase and Anthropic (`upstream.stripe`, `upstream.stripeCalls()`); Stripe's real form-urlencoded (not JSON) request bodies are asserted with `new URLSearchParams(body).get(...)`, bracket keys included. `test/stripe-webhook.test.ts` signs payloads itself (`signStripeWebhook`, `postStripeWebhook` in `test/helpers.ts`) with the same HMAC scheme `scripts/mock-stripe.mjs` uses, against the test's fixed `STRIPE_WEBHOOK_SECRET` canary.
- Not covered by this suite (mocked fetch, not a live server): a real `wrangler dev` + `mock-stripe.mjs` + `mock-supabase.mjs` run end to end, and real Supabase/Stripe (Day 16). `scripts/mock-stripe.mjs`'s own routes were checked standalone (see "Mock Stripe" above) rather than with a `node:test` contract-test file (unlike `mock-supabase.test.mjs`) — a reasonable next addition, not done here.

## Logging

One JSON line per `/v1/rewrite` request: `{"event":"rewrite","status":200,"latency_ms":412,"error":null,"user":"9f86d081884c"}`. `error` is a fixed kind (`unauthorized`, `tier_required`, `minute_limit`, `rewrite_failed`, ...), and `user` is the first 12 hex characters of SHA-256 of the user id (null before authentication). A misconfigured Worker additionally logs one fixed `misconfigured: ...` line to the error log (with no secret in it). Nothing else is logged: no transcript, rewritten text, token, key, raw user id or upstream response body. `test/logging.test.ts` enforces this.

## Still placeholders — decide before v1 ships

- **Rate limits** (`src/types.ts` `TIER_LIMITS`, `BILLING_LIMITS`, `ME_LIMITS`, etc.): 5/min, 3000/month for Pro rewrite/edit is a guess, so is 5/min · 30/month for billing session creation, and so is 60/min · 100,000/month for `GET /v1/me`. The PRD/TRD are explicit that pricing and quota sizing are unresearched — revisit with real usage data.
- **Rewrite model** (`src/claude.ts`): defaults to `claude-opus-5` with `max_tokens` 4096 (sized for the 16,000-character cap; dense non-English text can need more, and would then fail with 502 rather than be truncated). `eval/transcripts.json` (30 hand-authored samples) and `eval/run.mjs` (`npm run eval:rewrite`) exist to A/B this against `claude-haiku-4-5-20251001` on quality, latency and cost — **not yet run against a real model**: no `ANTHROPIC_API_KEY` exists in this environment (real accounts are Day 16). `eval/run.mjs` imports the exact `REWRITE_SYSTEM_PROMPT`/`REWRITE_MAX_TOKENS` this app ships (no copy-pasted prompt to drift), always runs the deterministic mock as a plumbing smoke check, and — once a real key is set — also calls the real API and prints latency/tokens/cost per sample plus a diff against the golden output. To get a real quality read: `ANTHROPIC_API_KEY=sk-... npm run eval:rewrite` (add `--model=claude-haiku-4-5-20251001` for the cheaper model), review the report, then update this line and `claude.ts`'s model constant with the numbers.
- **`past_due` mapping straight to `free`** (`src/stripeWebhook.ts`): unchanged pre-existing behavior, proven by a test rather than decided by this pass. Per CLAUDE.md, a `past_due` subscription flipping to Free instantly is a product decision (a grace period may be wanted), not something to default silently — **flagged for tech-lead**, not resolved here.
- **Checkout/portal return URLs** (`BILLING_SUCCESS_URL`/`BILLING_CANCEL_URL`/`BILLING_PORTAL_RETURN_URL`): fall back to placeholder `https://example.com/billing/...` pages when unset — there is no real domain yet (D1). Set these once one exists.
- **`POST /v1/billing/checkout`'s already-Pro guard doesn't cover every duplicate-Stripe-customer path** (`src/billing.ts`, `handleBillingCheckout`): it reads `profiles.tier`, which closes the common shape of "a prior checkout's `stripe_customer_id` save silently failed, so the next checkout call mints a second Stripe customer" once that earlier subscription's webhook has landed, but a genuine race (two concurrent checkout calls before either webhook lands) is not closed by this check. Closing it fully needs a Stripe subscription search by Supabase user, not just this tier read — flagged as low-priority (self-inflicted double-charge risk for one user, not a cross-user security boundary) rather than solved.
