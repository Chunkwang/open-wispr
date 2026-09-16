# open-wispr-proxy

Metered API Proxy — TRD Section 3.3. The only path from the client to the Claude API. Authenticates the request (Supabase JWT), checks the user's tier and quota, calls Claude, and updates tier on Stripe webhook events. No user content is stored — only usage counts for billing.

## Endpoints

- `POST /v1/rewrite` — body `{ "transcript": string }`, header `Authorization: Bearer <supabase session token>`. Returns `{ "rewritten": string }`.
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

## Still placeholders — decide before v1 ships

- **Rate limits** (`src/types.ts` `TIER_LIMITS`): 5/min, 3000/month for Pro is a guess. The PRD/TRD are explicit that pricing and quota sizing are unresearched — revisit with real usage data.
- **Rewrite model** (`src/claude.ts`): defaults to `claude-opus-5`. Worth A/B testing against `claude-haiku-4-5` for this specific task — grammar/punctuation cleanup is latency-sensitive and doesn't obviously need Opus-tier reasoning, but that's a quality/cost tradeoff only real output comparisons should decide.
- **Stripe Checkout Session creation isn't in this repo yet** — wherever that's built (this proxy, or a separate endpoint), it must set `metadata.supabase_user_id` on the subscription or the webhook has no way to know which Supabase row to update.
