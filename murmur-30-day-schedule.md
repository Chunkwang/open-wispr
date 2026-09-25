# Murmur — 30-Day Build Schedule

*Day 1 = Thursday 2026-09-24. Day 30 = Friday 2026-10-23. Companion to `murmur-implementation-plan.md` (task IDs like **1.4** refer to that file; **A1–A20** are new v2 agent tasks defined here).*

---

## Ground rules

- **Three blocks a day** (~10–11 hours): **Block 1** (~4h, the hard thing, do it fresh), **Block 2** (~4h), **Block 3** (~2–3h, small tasks plus the day's demo). A **Stretch** line is only for when you're ahead.
- **Every day ends with a demo and a commit.** The "Result" line is what you should be able to show. If the day is running late, drop Stretch and cut scope inside a block. **Never skip the demo**, or the next day starts on unverified work.
- **Light days** are 7, 14, 21, 28 (Wednesdays): one build block, then review and catch-up. They exist so a slipped day doesn't cascade.
- **No accounts until Day 16.** Per your call, we build against local stand-ins: a mock Supabase (auth, profiles), a mock Stripe (checkout, portal, signed webhooks), and a mock LLM provider in the proxy. The mock LLM is enabled only by a dev environment variable, never in the deployed Worker. Real accounts get wired in on Days 16–18.
- **Defaults I've assumed for the open decisions** (tell me if any is wrong): product identity kept in one place, `ProductInfo.swift`, and currently "Dictation (WIP)" (a display-name-only switch to "Murmur" needs no migration; the bundle ID must not change after Day 4, when tokens start living in Keychain; D1 must be settled by Day 15); magic-link sign-in (D2); rewrite auto-on-release behind a config flag (D3); test-mode price $12 with a 7-day trial (D4); opt-in, off-by-default anonymous counters (D5); model bundled in the app (D6); referral = extended trial for both sides (D7).
- **v2 ships behind a flag, off by default, and isn't marketed** (Days 19–30). That's the PRD's Section 13 gate: v1 usage data decides whether it's ever switched on for users.

## Milestones

| Day | Date | Milestone |
|---|---|---|
| 2 | Fri 09-25 | Dictate → cleaned text inserted (mock rewrite); falls back to raw when the backend is down |
| 5 | Mon 09-28 | Sign in with magic link (mock), token refresh, sign out |
| 7 | Wed 09-30 | Free → Pro upgrade works end to end on mocks |
| 10 | Sat 10-03 | Brand, trust docs and referral loop done |
| 15 | Thu 10-08 | **v1 release candidate** (everything built, all on mocks) |
| 18 | Sun 10-11 | **v1 beta live**: real accounts, notarized DMG, real payments in test mode, users invited |
| 23 | Fri 10-16 | Agent core: capture → intent → raw-parameter confirmation |
| 27 | Tue 10-20 | Calendar and Email handlers, action log, dry-run onboarding |
| 30 | Fri 10-23 | **v1.1 with the v2 agent preview** (flagged off), retrospective, next 30 days |

---

# Week 1 — Rewrite, backend, sign-in, billing (all on mocks)

## Day 1 · Thu 09-24 — Foundations and a testable rewrite client
**Result:** `swift test` runs green on your Mac, and the rewrite client has real tests.
- **Block 1 (4h):** **0.1** install Xcode and run the tests (start the download first; work on the other tasks while it installs), **0.3** reconcile min OS, **0.4** `NOTICE`, **0.5** `ProductInfo.swift`.
- **Block 2 (4h):** **1.1** make `RewritePipeline` injectable with typed errors and cover 401/402/429/5xx/timeout/bad JSON. **1.2** `rewriteMode` config with tests.
- **Block 3 (2h):** **0.2** architecture map, and **1.3** start: `mint-dev-token.mjs` and `.dev.vars.example`.
- **Stretch:** **1.3** finished with `mock-supabase.mjs`.
- **Your action:** Xcode download (~10 GB, start it immediately).

## Day 2 · Fri 09-25 — Rewrite works end to end, locally
**Result:** hold the key, say "um so like send it tomorrow", and cleaned text lands at your cursor. Stop the proxy and the raw text lands instead.
**Status:** met. The founder ran the real debug app against the local mocks on 2026-09-24 and got "Send it tomorrow." at the cursor. Still to try live (Day 2 stretch): the failure scenarios in `docs/local-dev.md` (proxy stopped, offline, free tier).
- **Block 1 (4h):** **1.3** finish: mock LLM provider in the proxy (removes fillers, fixes capitalisation; only when `LLM_PROVIDER=mock` **and** the request hostname is `127.0.0.1` or `localhost`, and `LLM_PROVIDER` is not in `wrangler.toml` or the required `Env` fields, so it cannot activate on a deployed Worker), mock Supabase profiles, `wrangler dev` run script.
- **Block 2 (4h):** **1.4** wire rewrite into `handleRecordingStop` with a ~6 s timeout and raw fallback. **Gate first (security review M2):** a single `RewriteGate.shouldRewrite(...)` that requires `rewriteMode == .auto` **and** a consent record kept outside `config.json` (UserDefaults or Keychain, carrying a disclosure version) **and** a session token. `handleRecordingStop` may only call that function. Until the disclosure sheet exists (Task 5.1, Day 8), the consent record can only be set by a dev-only path, so no build can send text without it. Unit-test every combination.
- **Block 3 (3h):** **1.5** rewriting state and fallback notice, **1.6** offline short-circuit, **1.7** menu toggle.
- **Stretch:** manual test log of five fallback scenarios.

## Day 3 · Sat 09-26 — Backend you can trust
**Result:** 20 parallel requests against a limit of 5 → exactly 5 succeed, proven by a test in CI.
- **Block 1 (4h):** **2.4** vitest harness (401, 402, 429, 400, 502 cases) plus a CI job.
- **Block 2 (4h):** **2.6** Durable Object quota (per-minute + monthly, counts only) with the parallel-request test.
- **Block 3 (2h):** **2.5** 413 on oversized transcripts (also cap `Content-Length`, and check `iss`/`aud` in `jwtVerify`), **2.7** content-free logging with a test. Add a startup check that the Worker refuses the known example secret from `.dev.vars.example`.
- **Stretch:** proxy README refresh.

## Day 4 · Sun 09-27 — Sign-in, part 1
**Result:** click "Sign in", enter an email, get a magic link (printed by the mock), and the app receives the callback.
- **Block 1 (4h):** extend `mock-supabase.mjs` into a proper auth mock: `/auth/v1/otp`, callback with access + refresh tokens, `/auth/v1/token` refresh, profiles. **2.3** make `auth.ts` accept HS256 or a JWKS (config-driven), both tested.
- **Block 2 (4h):** **3.1** URL scheme in `bundle-app.sh` and open-URL handling. **3.2** email window.
- **Block 3 (2h):** **2.2** write the `profiles` migration SQL with RLS (verified against the real project on Day 16).
- **Stretch:** start **3.3**.

## Day 5 · Mon 09-28 — Sign-in, part 2
**Result:** sign in, let the token expire, dictate anyway; it refreshes silently. Revoke it and the app says so calmly.
- **Block 1 (4h):** **3.3** callback parsing and Keychain storage of access + refresh + expiry. **3.4** session object into `RewritePipeline`.
- **Block 2 (4h):** **3.5** refresh logic with tests (expired → refresh once; revoked → signed out).
- **Block 3 (2h):** **3.6** menu sign in/out with email shown, **3.7** signed-out fallback and copy.
- **Stretch:** end-to-end manual script, sign in → dictate → expire → dictate.

## Day 6 · Tue 09-29 — Billing backend
**Result:** a mock "checkout" completes and your profile flips to Pro through a signed webhook.
- **Block 1 (4h):** `mock-stripe.mjs` (customers, checkout sessions, portal sessions) and Stripe SDK config pointing at it.
- **Block 2 (4h):** **4.2** `POST /v1/billing/checkout` with `supabase_user_id` metadata, **4.4** portal endpoint.
- **Block 3 (3h):** **4.3** webhook hardening (5xx on failed write, status mapping tests, bad signature, missing metadata, using locally generated signed payloads), **4.5** `GET /v1/me`.
- **Stretch:** idempotency for duplicate webhook events.

## Day 7 · Wed 09-30 — *Light day.* Billing in the app, and week 1 review
**Result:** Free user upgrades from the menu, becomes Pro without restarting.
- **Block 1 (4h):** **4.6** tier state, **4.7** upgrade flow with polling, **4.8** manage subscription, **4.9** 402 handling (once per session).
- **Review (2h):** run every stage 1–4 "Done when", fix what fails, update `murmur-implementation-plan.md` with what changed.
- **Catch-up (rest of day):** anything that slipped from Days 1–6.

---

# Week 2 — Trust, brand, growth loop, release pipeline

## Day 8 · Thu 10-01 — Trust and copy
**Result:** `TRUST.md` where each claim points at the file that proves it; the first-rewrite disclosure works.
- **Block 1 (4h):** **5.2** hotkey audit and reworded claim, **5.3** network egress inventory, `TRUST.md`.
- **Block 2 (4h):** **5.1** disclosure sheet, **5.4** no-network dictation test.
- **Block 3 (2h):** **6.1** extract `BrandColor` with semantic colours, **6.3** `Copy.swift`.
- **Stretch:** **6.4** copy lint.

## Day 9 · Fri 10-02 — Brand pass
**Result:** contrast test passes; every window looks on-brand in light and dark.
- **Block 1 (4h):** **6.2** WCAG contrast test and token fixes (emerald text, sage on light, amber), update `brand-color-system.md`.
- **Block 2 (4h):** **6.5** route all remaining strings through `Copy.swift`, **6.4** copy lint test.
- **Block 3 (2h):** **6.6** appearance screenshots into `docs/`.

## Day 10 · Sat 10-03 — Growth loop
**Result:** after a rewrite, "Copy before/after" gives you something shareable; a second account redeems your referral code and both get the trial extension (mock Stripe).
- **Block 1 (4h):** **7.1** in-memory pair, **7.2** menu item and share copy.
- **Block 2 (4h):** **7.3** referral schema, **7.4** redeem endpoint with tests (self-referral, reuse, unknown code).
- **Block 3 (3h):** **7.5** trial extension, **7.6** referral UI.

## Day 11 · Sun 10-04 — Metrics and rewrite quality harness
**Result:** diagnostics toggle sends nothing when off (tested); a fixed evaluation set runs against any model.
- **Block 1 (4h):** **7.7** opt-in diagnostics toggle, five events, `POST /v1/events`, extended no-network test.
- **Block 2 (4h):** **2.8** evaluation set (25 samples including the "ignore previous instructions" one) and the comparison script (runs on the mock now, on real models Day 16).
- **Block 3 (2h):** bug bash across Days 1–10.

## Day 12 · Mon 10-05 — Self-contained app
**Result:** the app transcribes with Homebrew's `whisper-cpp` uninstalled.
- **Block 1 (6h):** **8.2** build whisper.cpp with Metal in a script, place it at `Contents/Resources/whisper/whisper-cli`, check `otool -L`, and check that `Sparkle.framework` is embedded (fix if it isn't).
- **Block 2 (3h):** **8.3** bundle `base.en` and look for it before downloading.
- **Block 3 (1h):** confirm airplane-mode first launch.
- **Your action (recommended, 10 minutes):** start Apple Developer Program enrollment today. Approval time varies and Day 17 depends on it.

## Day 13 · Tue 10-06 — Packaging scripts
**Result:** one command produces a signed-structure `.app` and a `.dmg` locally.
- **Block 1 (4h):** **8.4** inside-out signing script with hardened runtime and microphone entitlement (identity is a parameter; ad-hoc for now).
- **Block 2 (4h):** **8.5** `notarize.sh` written to spec, **8.6** DMG script (unsigned locally, signed later).
- **Block 3 (2h):** verify the packaged app launches, asks for permissions and dictates from the DMG.
- **Note:** notarization can't be tested until Day 17; the scripts are written now so Day 17 is only running them.

## Day 14 · Wed 10-07 — *Light day.* Updates, and week 2 review
**Result:** an update signed with a wrong key is refused by the app.
- **Block 1 (4h):** **8.7** Sparkle wiring with a local test keypair, "Check for Updates…" menu, **8.8** local appcast, **8.9** unsigned/wrong-key rejection test recorded in `scripts/`.
- **Review (2h):** run every stage 5–8 "Done when".
- **Catch-up (rest of day).**

## Day 15 · Thu 10-08 — v1 release candidate
**Result:** a release-candidate DMG passes a clean-user-account run of the whole product.
- **Block 1 (4h):** **8.10** GitHub release workflow (dry run), **8.11** decide and fix the Homebrew path, README install section.
- **Block 2 (4h):** **9.1** full acceptance pass on a fresh macOS user account: onboarding, permissions, dictate, sign in, upgrade, rewrite, sleep/wake, update. File and fix each failure.
- **Block 3 (2h):** **9.2** in-app "Send feedback", and settle **D1** (the name) now, before Day 17's signing.
- **Milestone:** v1 RC: feature complete on mocks.

---

# Week 3 — Go live with real accounts, then start v2

## Day 16 · Fri 10-09 — Real backend
**Result:** you sign in with your real email and get a real Claude rewrite through the deployed Worker.
- **Your action (first 90 min):** create Supabase, Cloudflare and Anthropic accounts; hand me the URLs and set the secrets yourself (never paste keys into chat).
- **Block 1 (3h):** **2.1**, **2.2** run the migration, verify RLS (a user can't write `tier`), **2.3** confirm the JWT algorithm against the real project.
- **Block 2 (3h):** **2.10** deploy, **2.11** point the client at it, real end-to-end sign-in → dictate → rewrite.
- **Block 3 (3h):** **2.9** run the evaluation set on Opus vs Haiku, pick the model, record the numbers, add the anti-injection line to the prompt.

## Day 17 · Sat 10-10 — Real signing and updates
**Result:** a notarized DMG installs on a clean Mac with no Gatekeeper warning and updates itself.
- **Your action:** **8.1** Developer ID certificate and notarization credentials.
- **Block 1 (4h):** run **8.4–8.6** for real, fix notarization rejections (expect at least one).
- **Block 2 (3h):** host the appcast on your site, cut version N and N+1, prove the real update path, and repeat **8.9** against the hosted feed.
- **Block 3 (3h):** **8.10** run the release workflow from a tag with real secrets.
- **Risk:** if Apple enrollment isn't approved yet, this day slides. Days 18–19 flex; nothing else depends on it.

## Day 18 · Sun 10-11 — Real payments and beta invites
**Result:** **v1 beta live.** Real people can install, sign in, pay in test mode and rewrite.
- **Your action:** **4.1** Stripe test-mode product, price and webhook to the deployed Worker. **9.3** privacy policy and terms (I can draft from templates; you review them with legal input).
- **Block 1 (3h):** run the Stage 4 flows against real Stripe test mode.
- **Block 2 (4h):** **10.1** landing page copy in the brand voice, scoped honestly to v1.
- **Block 3 (3h):** **9.5** invite 10–20 non-founder users (include at least one person who dictates out of necessity). Set up a triage routine.
- **From here on, every day starts with a 30-minute beta triage.** Blocking bugs go first.

## Day 19 · Mon 10-12 — v2: agent foundations
**Result:** a separate agent hotkey opens a panel and shows what you said (local transcription only, nothing sent).
- **Block 1 (4h):** **A1** `agentEnabled` flag (off), `Sources/OpenWisprLib/Agent/` module, hotkey config, **A2** agent state machine: idle → listening → capturing → parsing → confirming → executing → done, with tests for illegal transitions.
- **Block 2 (4h):** **A3** reuse recorder and transcriber for agent instructions, invocation panel UI.
- **Block 3 (2h):** write the v2 addendum to the architecture doc; beta triage.

## Day 20 · Tue 10-13 — Screen capture, on invocation only
**Result:** invoke the agent → one screenshot is taken → thumbnail shown → discarded. Nothing captures unless you invoke it.
- **Block 1 (4h):** **A4** ScreenCaptureKit single-shot capture behind a narrow API callable only from the invocation path. The minimum macOS is 13, but `SCScreenshotManager` (the single-screenshot API) needs macOS 14 as far as I know, so verify that and gate the whole agent behind `#available(macOS 14, *)`: on macOS 13 the agent setting is hidden and the flag stays off.
- **Block 2 (4h):** **A5** Screen Recording permission with the plain-language explainer shown before the OS prompt (copy from the voice guide).
- **Block 3 (2h):** **A6** tests proving no capture without invocation and that the image is released afterwards.

## Day 21 · Wed 10-14 — *Light day.* Intent schema, and week 3 review
**Result:** a strict intent schema and a mock intent endpoint.
- **Block 1 (4h):** **A7** `{action_type, target_app, parameters}` Codable schema; unknown action types and extra fields are rejected. **A8** `POST /v1/agent/intent` in the proxy (mock provider, tier gate, size cap on images, its own rate limit).
- **Review (2h):** v1 beta metrics and feedback, week 3 checks.
- **Catch-up (rest of day).**

## Day 22 · Thu 10-15 — Real intent parsing
**Result:** with an email on screen, saying "reply saying yes, that works" produces a structured intent from real Claude vision.
- **Block 1 (4h):** **A9** vision call in the proxy with strict JSON output, downscaled image, no image retention.
- **Block 2 (4h):** **A10** client sends screenshot plus instruction; handle malformed or refused outputs (never guess an action).
- **Block 3 (2h):** **A11** injection test set: screens containing hidden instructions. The intent must not act on them, and where it does, Day 23's confirmation must expose it.

## Day 23 · Fri 10-16 — The Confirmation Layer (release blocker)
**Result:** any intent produces a dialog showing the raw resolved parameters in the danger colour, with Cancel as the default.
- **Block 1 (4h):** **A12** Action Router: dispatches typed intents to handlers, and **execution requires a confirmation token** that only the dialog can mint.
- **Block 2 (4h):** **A13** confirmation overlay: fields rendered directly from structured parameters (recipient, subject, event time), never a generated summary. Copy per the voice guide's clinical rule. `#C0392B` for the confirm button.
- **Block 3 (2h):** **A14** tests: the view model can only be built from raw parameters; execution without a token fails.

## Day 24 · Sat 10-17 — Action Log
**Result:** every proposed action appears in a log window with its status and raw parameters.
- **Block 1 (4h):** **A15** SQLite log (`id, timestamp, handler_type, status, raw_parameters, outcome, reversible`) using the system SQLite, no new dependencies. Status lifecycle: proposed → confirmed → executed / failed / cancelled.
- **Block 2 (4h):** **A16** Action Log window, empty-state copy from the guide, filtering.
- **Block 3 (2h):** persistence and crash-safety tests; beta triage.

## Day 25 · Sun 10-18 — Calendar handler
**Result:** *"lunch with Sam tomorrow at noon"* → confirmation → a real event on your calendar.
- **Block 1 (4h):** **A17** EventKit handler: permission flow, create event, treated as irreversible (warning colour path).
- **Block 2 (4h):** confirmation content for events, log entries, error paths (permission denied, no default calendar).
- **Block 3 (2h):** integration test on a real calendar.
- **Limitation to know now:** EventKit can't send invitations to other people. This handler creates events on your own calendar only; inviting attendees needs the Google Calendar API, which needs the OAuth setup listed under the risks below.

## Day 26 · Mon 10-19 — Email handler
**Result:** *"reply saying yes"* → confirmation showing the literal To, Subject and body → email sent through the mock Gmail server; a real Mail draft opens as the safe fallback.
- **Block 1 (4h):** **A18** provider protocol, OAuth PKCE flow with send-only scope against a mock Google server, tokens in Keychain.
- **Block 2 (4h):** email handler, rate limit (hourly/daily, enforced locally and recorded in the log), re-auth prompt when a provider call returns an auth error (TRD 8.6).
- **Block 3 (2h):** fallback that opens a Mail draft (reversible) when no account is connected.

## Day 27 · Tue 10-20 — Dry run and settings
**Result:** first-time agent enablement walks you through two simulated tasks with nothing executed.
- **Block 1 (4h):** **A19** dry-run onboarding (two canned tasks that show the confirmation UI without executing anything).
- **Block 2 (3h):** agent settings pane: enable flag, connect/disconnect accounts, permission status, and the plain-language explainer before each OS prompt.
- **Block 3 (3h):** copy pass through `Copy.swift` and the lint test; beta triage.

## Day 28 · Wed 10-21 — *Light day.* Adversarial testing, and week 4 review
**Result:** a written security test report for the agent layer.
- **Block 1 (5h):** **A20** attack pass: crafted screens with hidden text (the confirmation must show the attacker's address literally), fuzzed intent JSON, attempts to execute without a token, capture without invocation, and a look at how the log behaves under failures. Fix everything found.
- **Review (2h):** the TRD's "release blocker" list for the Confirmation Layer, item by item.

## Day 29 · Thu 10-22 — Real-world pass and hardening
**Result:** the agent works on your real screens and real calendar, and the flag-off build is byte-for-byte behaviour-identical to v1.
- **Block 1 (4h):** run 20 real tasks; log intent accuracy, latency and cost per call (the numbers the PRD's Path-to-v2 gate needs).
- **Block 2 (4h):** fix what breaks, plus the top beta-feedback items.
- **Block 3 (2h):** regression run of all v1 acceptance steps with the agent flag off.

## Day 30 · Fri 10-23 — Ship v1.1 and plan the next month
**Result:** a notarized v1.1 with the agent preview flagged off, and a written verdict on where you stand.
- **Block 1 (4h):** release v1.1 through the workflow; a scripted demo of v1 and v2.
- **Block 2 (3h):** update the PRD/TRD/implementation plan to match what was actually built; retrospective.
- **Block 3 (3h):** **9.6** decide the rewrite trigger from beta behaviour, **9.7** first read against the PRD's Path-to-v2 gate, and a backlog for days 31+ (live-mode Stripe, Google OAuth verification, usage dashboard, SEO page, launch post).

---

## Risks to watch (and when each bites)

| Risk | Day it matters | What to do |
|---|---|---|
| Apple Developer enrollment approval time | 17 | Start enrollment by Day 12. If it slips, swap Days 17 and 19–20; nothing else depends on it. |
| Notarization rejections (bundled helper binaries, hardened runtime) | 17 | Budgeted a full day. First-time notarization almost always needs one or two rounds. |
| Stripe live-mode activation | after 30 | Beta runs in test mode; live mode is post-schedule (task **9.4**). |
| Google OAuth verification for the send-mail scope | after 30 | It takes weeks and is outside our control. Start it during Week 4 if you want Email live for real users. The mock covers the build. |
| EventKit can't invite attendees | 25 | Documented limitation; Google Calendar API path arrives with the Google OAuth setup. |
| TRD asks for server-side email rate limits, but the client talks to the provider directly | 26 | I enforce local limits and log them. A server-side limit isn't possible without routing mail through us, which contradicts the trust architecture, so the TRD should be amended. |
| 10-hour days for 30 days | all | Light days are load-bearing. Skipping them is how a one-day slip becomes a one-week slip. |
