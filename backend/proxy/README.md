# open-wispr-proxy

Metered API Proxy — TRD Section 3.3. The only path from the client to the Claude API. Authenticates the request (Supabase JWT), checks the user's tier and quota, calls Claude, and updates tier on Stripe webhook events. No user content is stored — only usage counts for billing.

## Endpoints

- `POST /v1/rewrite` — body `{ "transcript": string }`, header `Authorization: Bearer <supabase session token>`. Returns `200 { "rewritten": string }`.
  Errors are always JSON `{ "error": string }`. Checks run in this order, and every check before the provider call is enforced on the server:

  | Status | `error` | When |
  |---|---|---|
  | 401 | `unauthorized` | Missing, malformed, tampered or expired token; wrong algorithm (only HS256 is accepted, for now); `aud` is neither `authenticated` nor a list that includes it; `iss` is not `${SUPABASE_URL}/auth/v1`; no `exp` claim; `sub` is not a UUID. Old dev tokens minted before the `iss` requirement land here too: re-mint with `npm run dev:token`. |
  | 413 | `transcript_too_long` | Two caps, both enforced: the request body is over 64 KB (65,536 bytes is accepted, 65,537 is not; checked from `Content-Length`, or while streaming when there is none), or `transcript` is over 16,000 characters, counted in Unicode code points (an emoji is one character). Sixteen thousand emoji is about 64,017 bytes, so it fits both caps. Nothing is looked up, counted or sent to the provider. |
  | 400 | `invalid request body` | Not valid UTF-8, not valid JSON, or not a JSON object. |
  | 400 | `missing transcript` | `transcript` is absent, empty, whitespace-only, or not a string. |
  | 402 | `rewrite requires the Pro tier` | The user is Free, or has no profile row. |
  | 429 | `minute_limit` or `monthly_limit` | Quota used up (Pro: 5 per minute, 3000 per month; placeholders). A request counts once it is admitted, and is not refunded if the provider then fails (502): the quota counts attempts. |
  | 502 | `rewrite failed` | The provider failed, was not answered within 90 s, or did not finish normally. Only `end_turn` and `stop_sequence` with non-empty text are accepted; `max_tokens`, `refusal`, `pause_turn`, `tool_use`, unknown reasons and empty text are all 502, so a cut-off or refused dictation is never returned as if it were complete. One attempt only, no retries. |
  | 503 | `service_unavailable` | The tier lookup (Supabase, 3 s deadline) or the quota store (Durable Object, 3 s deadline) failed, was unreachable or hung. Not a statement about the user's tier: the client should treat it as a temporary outage and retry later. No upstream details are included or logged. |
  | 500 | `misconfigured` | Off loopback, the Worker holds a `SUPABASE_JWT_SECRET` that is the published example, starts with `local-dev-`, or is under 32 characters. Fixed body on purpose; the cause is not stated. Set a real secret. |
  | 500 | `internal_error` | Anything unexpected. Fixed body, no stack trace. |

  Order of checks: config guard, authentication, body size and validation, tier, quota, provider. Malformed, oversized and unauthenticated requests never reach the tier lookup and never consume quota. Unauthenticated requests are answered 401 without their body being read.
- `POST /v1/stripe/webhook` — Stripe webhook receiver. Requires the subscription's `metadata.supabase_user_id` to be set when the Checkout Session is created. Off loopback it answers `500 {"error":"misconfigured"}` while `STRIPE_WEBHOOK_SECRET`, `STRIPE_SECRET_KEY` or `SUPABASE_SERVICE_ROLE_KEY` is still one of the `.dev.vars.example` placeholders (`whsec_placeholder`, `sk_test_placeholder`, `local-dev-service-role-key`).

## One-time setup

1. `npm install`
2. Nothing to create for quota: the `QUOTA` Durable Object binding and its migration (`new_sqlite_classes = ["QuotaCounter"]`) are in `wrangler.toml` and are applied by `npm run deploy`.
3. Set `SUPABASE_URL` in `wrangler.toml`'s `[vars]`.
4. Set secrets (never committed):
   ```
   npx wrangler secret put SUPABASE_JWT_SECRET
   npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
   npx wrangler secret put ANTHROPIC_API_KEY
   npx wrangler secret put STRIPE_SECRET_KEY
   npx wrangler secret put STRIPE_WEBHOOK_SECRET
   ```
5. In Supabase, create a `profiles` table with at least `id uuid` (matches `auth.users.id`) and `tier text default 'free'`.
6. `npm run dev` to run locally, `npm run deploy` to ship.

## Local development

No accounts or real keys are needed to run the whole rewrite path locally: the Worker under `wrangler dev`, a mock Supabase, and a mock LLM. There is no auth bypass in the Worker: it verifies a real HS256 JWT (audience `authenticated`, issuer `${SUPABASE_URL}/auth/v1`), and you mint one with your own local secret.

1. `cp .dev.vars.example .dev.vars` (gitignored; placeholder values only). `SUPABASE_JWT_SECRET` must start with `local-dev-`: the token script refuses anything else, so a real project secret can't be used by accident. (The Worker in turn refuses such a secret off loopback.)
2. In `.dev.vars`, uncomment `LLM_PROVIDER=mock`. Without it the Worker calls the real Claude API, which fails with the placeholder key.
3. Terminal 1: `npm run dev:mock` starts the mock Supabase on `http://127.0.0.1:54321` (`PORT=...` to change it).
4. Terminal 2: `npm run dev` starts `wrangler dev` on `http://127.0.0.1:8787`.
5. Terminal 3: mint a token and call the proxy:
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

In-memory, `node:http`, no dependencies, bound to 127.0.0.1. It implements only what the Worker calls today:

- `GET /rest/v1/profiles?id=eq.<uuid>&select=tier` returns `[{"tier":"pro"}]`.
- `PATCH /rest/v1/profiles?id=eq.<uuid>` with `{"tier":"free"|"pro"}` sets that user's tier (the Stripe webhook path). Answers 204 for `Prefer: return=minimal`.

Requests without `apikey` and `Authorization` headers get 401, as Supabase would. Users never PATCHed get `MOCK_TIER` (default `pro`): `MOCK_TIER=free npm run dev:mock` makes `/v1/rewrite` answer 402. State resets when the mock restarts. `MOCK_FAIL=503` makes every request answer 503 and `MOCK_FAIL=drop` closes the connection without answering, to exercise the Worker's `service_unavailable` path.

### Mock LLM (`src/llmProvider.ts`)

Deterministic and text-only: it strips fillers (um, uh, "you know", a leading "so", "like" used as a filler), collapses spaces, fixes a lone lowercase "i", capitalises, and adds a final full stop. It never follows instructions inside the transcript.

It is used only when `LLM_PROVIDER=mock` is set AND the request hostname is `127.0.0.1` or `localhost` (`chooseProvider`). Any other case falls back to the real Claude path. `LLM_PROVIDER` must never appear in `wrangler.toml` or as a Wrangler secret.

### Tokens

`npm run dev:token -- [user-id] [--ttl <seconds>]` prints only the token. `user-id` must be a UUID (the Worker rejects any other subject). It defaults to a fixed dev user id and a 1 hour lifetime, and takes the secret from the `SUPABASE_JWT_SECRET` env var, else `.dev.vars`. It exits non-zero with a message if neither is set, and refuses any secret that does not start with `local-dev-`. The token's issuer is `${SUPABASE_URL}/auth/v1` with `SUPABASE_URL` from the env var, else `.dev.vars`, else `http://127.0.0.1:54321`; keep it equal to the Worker's `SUPABASE_URL`, or the Worker answers 401.

Use a different user id to get a fresh quota (Pro is 5 requests per minute per user). Quota state lives in the local Durable Object storage under `.wrangler/`; delete that folder to reset everyone.

## Quota (`src/quotaCounter.ts`, `src/rateLimit.ts`)

Per-user quota is a Durable Object, one `QuotaCounter` per user id (`QUOTA.idFromName(userId)`). Its single method `consume(limits, nowMs)` checks the per-minute and per-month windows and increments both inside one synchronous storage transaction, so parallel requests cannot interleave between the read and the write (the old KV read-then-write let 30 parallel requests through a limit of 5). A denied request is not counted. It stores counts only (one row per active window: kind, window, count), never content and not even the user id, and deletes expired windows on every write. The Worker computes the limits from `TIER_LIMITS` and passes `nowMs`; windows are the UTC minute and UTC month. The Worker waits at most 3 s for the Durable Object; a failure, timeout or unreachable object is a 503 `service_unavailable`.

## Tests

`npm test` runs vitest inside real workerd (`@cloudflare/vitest-pool-workers`, config in `vitest.config.mts`), and `npm run typecheck` covers `src/` and `test/`. CI runs both in the `backend` job.

- Every request goes through the Worker's `fetch` handler (`test/helpers.ts` `call()`), never through internals such as `rateLimit.ts`. Outbound calls (Supabase, Anthropic) are answered by a fetch mock in `test/helpers.ts`; any other outbound URL throws, so a test cannot reach the network.
- Bindings are fixed fake values set in `vitest.config.mts`, and `LLM_PROVIDER` is off unless a test sets it, so the run does not depend on your `.dev.vars` (which may enable the mock LLM). The Supabase and Anthropic keys there are canary strings that the logging tests search for.
- Tokens are minted per test with `jose` and a `local-dev-` secret. Each test uses a fresh user id, so quotas never collide.
- Test files: `test/rewrite.test.ts` (auth, tier, quota basics, body and size validation, mock LLM guard, Claude path, outages), `test/hardening.test.ts` (Claude finish reasons and single attempt, deployed-host guard, loopback set, token claims, URL normalisation, size and code-point caps), `test/quota.test.ts` (real Durable Object: parallel-burst atomicity, per-user isolation, window resets, month limit, storage contents, 503 on failure or hang) and `test/logging.test.ts` (success and every failure path, with console spies, asserting nothing sensitive is ever logged).
- Quota tests use a real `QuotaCounter` in workerd. Tests that send several requests freeze only `Date` (`freezeClock()`) so no minute boundary can fall inside a test. Only `brokenQuotaEnv()` and `hangingQuotaEnv()` in `test/helpers.ts` name the quota binding.
- Not covered yet: the Stripe webhook logic (Task 4.3) and real Supabase (Day 16).

## Logging

One JSON line per `/v1/rewrite` request: `{"event":"rewrite","status":200,"latency_ms":412,"error":null,"user":"9f86d081884c"}`. `error` is a fixed kind (`unauthorized`, `tier_required`, `minute_limit`, `rewrite_failed`, ...), and `user` is the first 12 hex characters of SHA-256 of the user id (null before authentication). A misconfigured Worker additionally logs one fixed `misconfigured: ...` line to the error log (with no secret in it). Nothing else is logged: no transcript, rewritten text, token, key, raw user id or upstream response body. `test/logging.test.ts` enforces this.

## Still placeholders — decide before v1 ships

- **Rate limits** (`src/types.ts` `TIER_LIMITS`): 5/min, 3000/month for Pro is a guess. The PRD/TRD are explicit that pricing and quota sizing are unresearched — revisit with real usage data.
- **Rewrite model** (`src/claude.ts`): defaults to `claude-opus-5` with `max_tokens` 4096 (sized for the 16,000-character cap; dense non-English text can need more, and would then fail with 502 rather than be truncated). Worth A/B testing against `claude-haiku-4-5` for this specific task — grammar/punctuation cleanup is latency-sensitive and doesn't obviously need Opus-tier reasoning, but that's a quality/cost tradeoff only real output comparisons should decide.
- **Stripe Checkout Session creation isn't in this repo yet** — wherever that's built (this proxy, or a separate endpoint), it must set `metadata.supabase_user_id` on the subscription or the webhook has no way to know which Supabase row to update.
