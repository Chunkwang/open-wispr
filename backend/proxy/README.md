# open-wispr-proxy

Metered API Proxy — TRD Section 3.3. The only path from the client to the Claude API. Authenticates the request (Supabase JWT), checks the user's tier and quota, calls Claude, and updates tier on Stripe webhook events. No user content is stored — only usage counts for billing.

## Endpoints

- `POST /v1/rewrite` — body `{ "transcript": string }`, header `Authorization: Bearer <supabase session token>`. Returns `{ "rewritten": string }`.
  Errors are always JSON `{ "error": string }`:
  - `401 unauthorized` missing or invalid token
  - `402 rewrite requires the Pro tier`
  - `429 minute_limit` or `monthly_limit`
  - `400 invalid request body` or `missing transcript`
  - `502 rewrite failed` the LLM call failed
  - `503 service_unavailable` the tier lookup (Supabase) or quota store failed. Not a statement about the user's tier: the client should treat it as a temporary outage and retry later. No upstream details are included or logged.
- `POST /v1/stripe/webhook` — Stripe webhook receiver. Requires the subscription's `metadata.supabase_user_id` to be set when the Checkout Session is created.

## One-time setup

1. `npm install`
2. `npx wrangler kv namespace create RATE_LIMIT_KV`, paste the returned id into `wrangler.toml`.
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

No accounts or real keys are needed to run the whole rewrite path locally: the Worker under `wrangler dev`, a mock Supabase, and a mock LLM. There is no auth bypass in the Worker: it verifies a real HS256 JWT, and you mint one with your own local secret.

1. `cp .dev.vars.example .dev.vars` (gitignored; placeholder values only). `SUPABASE_JWT_SECRET` must start with `local-dev-`: the token script refuses anything else, so a real project secret can't be used by accident.
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

Use `127.0.0.1` or `localhost` in the URL. The mock LLM is not used on any other hostname.

### Mock Supabase (`scripts/mock-supabase.mjs`)

In-memory, `node:http`, no dependencies, bound to 127.0.0.1. It implements only what the Worker calls today:

- `GET /rest/v1/profiles?id=eq.<uuid>&select=tier` returns `[{"tier":"pro"}]`.
- `PATCH /rest/v1/profiles?id=eq.<uuid>` with `{"tier":"free"|"pro"}` sets that user's tier (the Stripe webhook path). Answers 204 for `Prefer: return=minimal`.

Requests without `apikey` and `Authorization` headers get 401, as Supabase would. Users never PATCHed get `MOCK_TIER` (default `pro`): `MOCK_TIER=free npm run dev:mock` makes `/v1/rewrite` answer 402. State resets when the mock restarts. `MOCK_FAIL=503` makes every request answer 503 and `MOCK_FAIL=drop` closes the connection without answering, to exercise the Worker's `service_unavailable` path.

### Mock LLM (`src/llmProvider.ts`)

Deterministic and text-only: it strips fillers (um, uh, "you know", a leading "so", "like" used as a filler), collapses spaces, fixes a lone lowercase "i", capitalises, and adds a final full stop. It never follows instructions inside the transcript.

It is used only when `LLM_PROVIDER=mock` is set AND the request hostname is `127.0.0.1` or `localhost` (`chooseProvider`). Any other case falls back to the real Claude path. `LLM_PROVIDER` must never appear in `wrangler.toml` or as a Wrangler secret.

### Tokens

`npm run dev:token -- [user-id] [--ttl <seconds>]` prints only the token. It defaults to a fixed dev user id and a 1 hour lifetime, and takes the secret from the `SUPABASE_JWT_SECRET` env var, else `.dev.vars`. It exits non-zero with a message if neither is set.

Use a different user id to get a fresh quota (Pro is 5 requests per minute per user).

## Still placeholders — decide before v1 ships

- **Rate limits** (`src/types.ts` `TIER_LIMITS`): 5/min, 3000/month for Pro is a guess. The PRD/TRD are explicit that pricing and quota sizing are unresearched — revisit with real usage data.
- **Rewrite model** (`src/claude.ts`): defaults to `claude-opus-5`. Worth A/B testing against `claude-haiku-4-5` for this specific task — grammar/punctuation cleanup is latency-sensitive and doesn't obviously need Opus-tier reasoning, but that's a quality/cost tradeoff only real output comparisons should decide.
- **Stripe Checkout Session creation isn't in this repo yet** — wherever that's built (this proxy, or a separate endpoint), it must set `metadata.supabase_user_id` on the subscription or the webhook has no way to know which Supabase row to update.
