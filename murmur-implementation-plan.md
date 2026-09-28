# Murmur — v1 Implementation Plan

*Companion to `murmur-prd.md`, `murmur-trd.md`, `brand-color-system.md` and `brand-voice-tone-guide.md`. Scope is v1 only (dictation + rewrite). The agent layer stays behind the PRD's Section 13 gate and is not planned here.*

*Written against the repo as of 2026-09-24 (v0.43.0, `main` clean).*

---

## Product bets: how we are better

*Decided 2026-09-25 from `docs/competitive-teardown.md` (desk research on HeyClicky and Wispr Flow; the hands-on half is `docs/heyclicky-teardown-checklist.md`). "Better" has to be provable, so each bet has a test we can run. These four are the reason the product exists; everything else is optional.*

**Bet 1: Private by construction.** Speech becomes text on the user's Mac. Both competitors send audio or screens to a cloud (Wispr: "transcription always occurs on the cloud"; HeyClicky: "everything is processed in the cloud", and it keeps the AI's analysis of each screenshot and the prompt). We send only what the user has agreed to, show what will be sent before it is sent, skip password fields, and keep nothing on our servers.
*Proof:* dictation works with the network off; the proxy never logs content (tests exist); a "what will be sent" preview exists for every data type that leaves the Mac.

**Bet 2: Verifiably trustworthy.** Open MIT core, and every public claim traced to code (`TRUST.md`) and, where possible, enforced by a test or CI check (as the release-binary consent check already is). Wispr's privacy incident shows an unverifiable claim can cost a reputation ("no audit path for a user"). Irreversible actions show the real address or command, never a friendly summary.
*Proof:* each claim in `TRUST.md` points at a file and a check; anyone can build from source and get the same behaviour.

**Bet 3: Reliable and light.** Never lose the user's words: if the network, server or account fails, the raw transcript still lands. Cloud-only rivals inherit their servers' outages (Wispr: 75+ logged outages since Dec 2025, per a competitor-run tracker summary). Small and quiet: one hotkey per job, few permission prompts, each asked for only when first needed and explained first.
*Proof:* a standing outage drill (server off, Wi-Fi off, signed out: words still appear, with a calm notice); an idle memory and CPU budget measured against the competitors in the hands-on hour.

**Bet 4: Priced for individuals.** Unlimited free local dictation forever (it costs us nothing to run); Pro priced below the incumbents' individual plans (Wispr Pro $15 a month, or $12 annual; HeyClicky Pro $20); action limits described as outcomes ("100 agent actions a month"), not tokens.
*Proof:* the pricing page; unit cost per rewrite and per Ask measured on Day 16 (Task 2.9) before any price is final.

**What we deliberately do not compete on (for now):** spoken replies, breadth of models and integrations, enterprise compliance (SOC 2, HIPAA), Windows. *(Founder decision 2026-09-25: an on-screen pointer that shows where to click IS included in the first V2 version, as task C13, added scope of roughly a week; drawing freehand annotations is not.)*

**Feature gate.** Every new task or feature must name which bet it serves in one line. If it serves none, it waits. The tech-lead persona checks this in review. (Existing stages map like this: Stages 1-5 serve bets 1-3; Stage 4 billing and the pricing page serve bet 4; Stage C serves bets 1 and 2 first; the Email/Calendar agent serves bet 2 through raw-parameter confirmations.)

**Known risks to these bets:** the MIT HeyClicky reference client means the "screen buddy" idea itself has no feature moat, so trust, reliability and price must carry us; Apple may build on-screen awareness into the OS; a single false privacy claim would undo bet 2, so claims stay conservative.

---

## How to use this plan

- **One task = one PR.** Every task is small enough to finish and merge on its own, and each one leaves the app working.
- **Sizes:** **S** ≈ under an hour. **M** ≈ half a day. **L** ≈ a day. Nothing is bigger than L; if it grows, split it.
- **Tags:** **[YOU]** means only you can do it (accounts, keys, legal). **[DECIDE]** means a choice is needed before the tasks marked "blocked by" it.
- **Every task has a "Done when"**, a check you can run or watch. If you can't check it, it isn't done.
- **Order matters within a stage; stages 1–4 are strictly sequential**, because each builds on the last. Stages 5–7 can interleave once stage 4 is done. Stage 8 (release pipeline) has to finish before Stage 9 (beta).

---

## Where the repo is today

**Already built (don't redo):**
- Local dictation: hotkey, recording, whisper transcription, text insertion, model download, onboarding window with the brand voice's v1 copy, sleep/wake recovery, config, tests (`Sources/OpenWisprLib/`).
- `RewritePipeline.swift`: a working client for `POST /v1/rewrite`. (Day 2: now called from the dictation flow behind `RewriteGate`; no sign-in flow feeds it a real token yet.)
- `backend/proxy/`: Cloudflare Worker with JWT auth, tier check, KV rate limiting, Claude call, Stripe webhook. **Never deployed**; `wrangler.toml` still has placeholders. No tests.
- `Keychain.swift`, `UpdaterController.swift` (Sparkle wrapper, **not wired in**), `BrandColor` (inside `OnboardingWindow.swift`).

**Gaps found while reading the code. These shaped the plan:**

| # | Finding | Where it lands |
|---|---|---|
| 1 | Local tests can't run: this Mac has Command Line Tools only (no XCTest), and `.build/` is stale from before the folder rename. CI is the only place tests run. | 0.1 |
| 2 | The client stores a single session token. Supabase access tokens expire (typically hourly), so Pro users would be silently signed out. No refresh logic exists. | 3.5 |
| 3 | No sign-in UI exists at all. `setSessionToken` is never called. | Stage 3 |
| 4 | Rate limiting uses KV read-then-write. That isn't atomic and KV is eventually consistent, so parallel requests can exceed the quota. The TRD calls this "the actual control." | 2.6 |
| 5 | The proxy has no transcript length cap, so one request can be arbitrarily expensive. | 2.5 |
| 6 | The Stripe webhook ignores whether its Supabase write succeeded. A failed write returns 200, Stripe doesn't retry, and a paying user stays on Free. | 4.3 |
| 7 | `auth.ts` hard-codes HS256 with a shared secret. Newer Supabase projects may issue asymmetric-signed tokens instead. Needs checking against the real project. | 2.3 |
| 8 | `bundle-app.sh` ad-hoc signs and copies **only the binary**: no Sparkle framework, no `whisper-cli`, no model. It also lacks the URL scheme sign-in needs. (`Transcriber` already looks for a bundled `whisper/whisper-cli`, so half of the bundling is prepared.) I couldn't confirm the framework problem because there's no local release build. Verify in 8.2. | Stage 8 |
| 9 | The app depends on Homebrew's `whisper-cpp` and downloads the model from the network on first run. The PRD's "zero network requests" and the TRD's "models ship in the bundle" are both untrue today. | 5.3, 8.3 |
| 10 | The hotkey listener (`NSEvent` global monitor) receives every keystroke system-wide and only compares key codes. That's verifiable and fine, but "never reads keystrokes" is stronger than the truth. The claim needs precise wording. | 5.2 |
| 11 | Package.swift and the plist said macOS 13; the PRD said Sonoma 14.2+. **Resolved 2026-09-24: founder chose macOS 13** and the PRD line was updated. | 0.3 |
| 12 | Brand contrast: white on emerald is 4.50:1 (barely passes AA). Emerald text on either background is ~4.2:1 (fails for body text). Sage text on light is 2.79:1 (fails). White on amber is 3.25:1 (fails). Forest green on the dark background is 1.71:1 (unusable as text or border). Computed from the hexes in `brand-color-system.md`. | 6.2 |
| 13 | The PRD's north-star metric needs `dictation_completed`, but the TRD says no default telemetry. They conflict. | Decision D5 |
| 14 | `Formula/open-wispr.rb` still points at upstream `human37/open-wispr` v0.9.1. | 8.11 |

---

## Decisions needed (in the order they block work)

| ID | Decision | My recommendation | Blocks |
|---|---|---|---|
| **D1** | Final product name (trademark check) | Decide before Stage 8. Changing the bundle ID after notarization breaks Keychain items, permissions and Sparkle update continuity. | 0.5, 8.x, 10.x |
| **D2** | Sign-in method: email magic link vs email code vs Sign in with Apple | **Decided 2026-09-25: email code first** (type the 6-digit code from the email). A link needs a URL scheme the bare dev binary cannot receive, and corporate email scanners burn one-time links; codes have neither problem. Link and Sign in with Apple can follow. Full design: `docs/auth-design.md`. | 3.x |
| **D3** | Rewrite trigger: auto on release vs second hotkey | Ship auto-on-release behind a config flag (Stage 1), and let beta data decide (9.6). The TRD already says to decide this with real usage. | 1.4, 9.6 |
| **D4** | Pro price and trial length | Test-mode placeholder ($12, 7-day trial); PRD says pricing is unresearched. Changeable later without code changes. | 4.1 |
| **D5** | Telemetry: how to count `dictation_completed` without breaking "no default telemetry" | Opt-in, off by default, anonymous counters only (random install ID, no content). Tell users exactly what is sent. | 7.7 |
| **D6** | Ship the model inside the app (TRD 3.1) vs download on first run | Bundle `base.en` (142 MB) for true offline-out-of-the-box. If the DMG size is a problem, download on first run and reword the "zero network" claim honestly. | 5.3, 8.3 |
| **D7** | Referral mechanism (PRD: extended trial for both sides, unvalidated) | Keep the assumption; build it after the core billing loop works. | 7.4–7.6 |

---

## Stage 0 — Groundwork (unblock everything)

**0.1 Get tests running locally** · S · **[YOU]**
Install full Xcode (or point `xcode-select` at it), then `rm -rf .build` (stale Sparkle path from the folder rename; it's gitignored).
*Done when:* `swift test` runs the existing 9 test files green on your machine.
**Done 2026-09-24:** Xcode 27.0 installed, stale `.build` cleared, plain `swift test` runs 319 tests with 0 failures (the local stand-in runner had reported 318 of the same tests; the extra one is the network-dependent model-URL test).

**0.2 Map the TRD's components to files** · S
One short `docs/architecture.md` mapping each TRD v1 component to its actual file (`RewritePipeline`, `backend/proxy/src/*`, etc.), so later tasks can be cross-referenced.
*Done when:* every TRD v1 component appears with its file path.

**0.3 Reconcile minimum OS** · S
Decided: macOS 13 (Ventura). Update `Package.swift`, `LSMinimumSystemVersion` in `scripts/bundle-app.sh`, and README.
*Done when:* `Package.swift`, `scripts/bundle-app.sh`, the README and `ProductInfo` all say the same version (drift is test-checked). `index.html` and `llms.txt` still say macOS 13 and are deliberately left for the Stage 10 site rewrite: `deploy.yml` publishes `index.html` on any push to `main`, and the site still promotes the upstream Homebrew install.

**0.4 Licence notices** · S
Keep `LICENSE` (MIT, upstream's copyright line intact). Add `NOTICE` covering whisper.cpp (MIT) and Sparkle (MIT).
*Done when:* `NOTICE` exists and is referenced from the README. (PRD open question "MIT compliance" then has a concrete answer.)

**0.5 Single source for the product name** · S · *soft-blocked by D1*
Add `ProductInfo.swift` (display name, bundle ID, support URL) and use it in the onboarding window, status bar and `bundle-app.sh`, so a rename is a one-file change.
*Done when:* no user-visible product name in `Sources/` outside `ProductInfo.swift`. The `open-wispr` CLI/binary name, its help text and the `~/.config/open-wispr` directory stay until the rename itself, which needs a config migration (documented in `ProductInfo.swift`).

---

## Stage 1 — Rewrite works end to end, locally (no accounts needed)

**1.1 Make `RewritePipeline` testable and its errors typed** · S
Inject a `URLSession` instead of `URLSession.shared`, make the call `async`, and map 401 → `.unauthorized`, 402 → `.requiresPro`, 413 → `.tooLong`, 429 → `.rateLimited`, 5xx → `.unavailable`, timeouts → `.timedOut` (a hard total deadline), cancellation → `.cancelled`, no connection → `.offline`.
*Done when:* unit tests (with a `URLProtocol` stub) cover success, 401, 402, 429, 500, timeout and malformed JSON.

**1.2 Add `rewriteMode` to Config** · S
`off` (default) or `auto`. Old config files without the key must still load.
*Done when:* `ConfigTests` cover missing, `off`, `auto` and invalid values.

**1.3 Local dev loop for the proxy** · S
`backend/proxy/scripts/mint-dev-token.mjs` (signs an HS256 token with a dev secret), `scripts/mock-supabase.mjs` (serves `/rest/v1/profiles` returning `pro`), and `.dev.vars.example`. No auth bypass in production code.
*Done when:* `wrangler dev` plus a minted token and the local mocks (mock Supabase, `LLM_PROVIDER=mock` in `.dev.vars`) makes `curl /v1/rewrite` return rewritten text; no Anthropic key or accounts needed. (Met on Day 2; verified by two independent runs.)

**1.4 Wire rewrite into the dictation flow** · M · *see D3*
In `AppDelegate.handleRecordingStop`, after transcription: if `RewriteGate` says yes (`rewriteMode == auto` **and** a consent record for the current disclosure version **and** a session token), call `rewrite` with a ~6 s hard deadline, then insert the result. On any failure insert the raw transcript. Keep the raw text in `lastTranscription`.
*Done when:* with the dev proxy running, dictating inserts cleaned text; with the proxy stopped, dictating inserts the raw text and nothing hangs.

**1.5 Status bar "rewriting" state and fallback notice** · S
Put the `RewriteError` → user-facing copy mapping in one extension (tasks 1.5, 1.6, 3.7 and 4.9 all need it; don't repeat it at call sites). `.cancelled` shows no notice.
Add a `.rewriting` state and show the brand copy verbatim on failure: *"Couldn't reach the rewrite service. Your raw transcript was inserted instead — nothing was lost."*
*Done when:* both states are visible in the menu bar during a manual run.

**1.6 Offline short-circuit** · S
Use `NWPathMonitor`; when offline skip the network call, insert raw, and say so plainly (TRD 6: "clear, honest in-app message").
*Done when:* with Wi-Fi off, dictation works, the notice appears, and no request is attempted.

**1.7 "Rewrite" toggle in the menu** · S
Menu item writes `rewriteMode`, with a status line showing why rewrite is or isn't active. It is always clickable; the gate decides whether anything is sent. Hidden in release builds until the disclosure sheet (Task 5.1) can grant consent.
*Done when:* toggling persists across restart and changes behaviour without a relaunch.

---

## Stage 2 — Backend made real and safe

**2.1 Create the Supabase project** · S · **[YOU]**
*Done when:* you have the project URL, JWT settings and service-role key.

**2.2 `profiles` migration with RLS** · S
`backend/supabase/migrations/0001_profiles.sql`: `profiles(id, tier default 'free', stripe_customer_id)`, an insert trigger on `auth.users`, and row-level security so a signed-in user can read their own row but **cannot write `tier`**.
*Done when:* a new test user gets a `free` row automatically, and an attempt to `update profiles set tier='pro'` with the user's own token fails.

**2.3 Confirm and fix JWT verification** · S
Check whether the project signs with HS256 or asymmetric keys. If asymmetric, switch `auth.ts` to a remote JWKS.
*Done when:* a real Supabase-issued token is accepted and a tampered one is rejected.

**2.4 Proxy test harness** · M  **[DONE 2026-09-25]**
Add vitest. Cover: missing/invalid token → 401, Free → 402, over-quota → 429, empty transcript → 400, Claude failure → 502, and a Supabase outage (today `getUserTier` lets the fetch failure escape as a 500 with a stack trace, and a non-OK response is treated as Free; a Pro user during an outage should get a 503, not a false upgrade prompt). **Done on Day 2** for a failed or dropped Supabase call and a failing quota call (JSON 503, no upstream details); still open: give the Supabase `fetch` a timeout so a *hung* upstream also becomes a 503 instead of hanging the request, and add automated tests for all of it.
*Done when:* `npm test` passes and CI runs it (add a job to `ci.yml`).

**2.5 Cap transcript length** · S  **[DONE 2026-09-25]** (16,000 characters counted as code points, plus a 64 KB body cap; body validated before quota)
(Also: cap `transcript.length` at ~16,000 chars with a 413, and fail the request when Claude's `stop_reason` is `max_tokens` (today a long dictation is silently truncated and the truncated text is inserted as if complete). And `handleRewrite` consumes quota *before* validating the body, so malformed requests burn a user's per-minute allowance; validate first. And URL-encode `userId` when building the Supabase REST URLs in `tier.ts` and `stripeWebhook.ts`.)
Reject transcripts over a fixed limit (start at 8,000 chars) with 413.
*Done when:* a test posts a 100,000-char body and gets 413 without any Claude call being made.

**2.6 Make the quota atomic** · M  **[DONE 2026-09-25]** (Durable Object; 20 parallel requests admit exactly 5, proven in tests and in a real `wrangler dev` run)
(Also return a machine-readable body such as `{"error":"rate_limited","scope":"minute|month"}`; the client can then tell the two apart without parsing free text.)
Replace the KV counters with a Durable Object (per-user), keeping the per-minute and monthly caps. Store counts only, never content (TRD 3.3).
*Done when:* a test fires 20 parallel requests against a limit of 5 and exactly 5 succeed.

**2.7 Content-free request logging** · S  **[DONE 2026-09-25]**
Log status, latency and a hashed user ID. Add a test asserting no transcript text appears in logs.
*Done when:* the test passes.

**2.8 Rewrite evaluation set** · M
`backend/proxy/eval/transcripts.json` with 20–30 fixed samples: filler words, false starts, numbers, names, non-English, very short, code-ish text, and an "ignore previous instructions" line (dictated text is untrusted). Script prints before/after plus a length ratio.
*Done when:* one command produces a review table for the current prompt and model.

**2.9 Choose model and prompt** · S
Run 2.8 against `claude-opus-5` and `claude-haiku-4-5-20251001`; compare quality, latency and cost. Update `claude.ts` and the README placeholder note. Add a line to the system prompt to treat the transcript as text, not instructions.
*Done when:* the chosen model and its numbers are written in `backend/proxy/README.md`, and the injection sample is returned as text, not obeyed.

**2.10 Deploy to a staging Worker** · S · **[YOU]**
Create the Durable Object binding, set the five secrets, `npm run deploy`.
*Done when:* `curl` with a real user token from your laptop returns a rewrite.

**2.11 Point the client at the deployed URL** · S
Replace the placeholder in `RewritePipeline.swift`; keep the env-var override.
*Done when:* the built app rewrites against staging.

---

## Stage 3 — Sign-in *(blocked by D2; plan assumes magic link)*

**3.1 Register a URL scheme** · S  **[DEFERRED: not needed for email-code sign-in; revisit if a link or OAuth redirect flow is wanted]**
Add `CFBundleURLTypes` to the plist in `bundle-app.sh` and handle the open-URL callback in `AppDelegate`.
*Done when:* running `open "<scheme>://auth?test=1"` reaches the app and logs the URL.

**3.2 Request a sign-in code** · S
Small SwiftUI window: email field → Supabase `POST /auth/v1/otp`. Brand colours, copy from `Copy.swift` once 6.3 exists (plain strings until then).
*Done when:* entering your email delivers a link.

**3.3 Verify the code and store the session** · M
Parse access token, refresh token and expiry from the callback. Store all three in Keychain (extend `Keychain.swift` usage; `RewritePipeline` currently stores one token only). Harden `Keychain.set` while here (security review): set `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, use update-or-add instead of delete-then-add, and surface the `OSStatus` (never log the value). The refresh token is only safe under a stable Developer ID signature; ad-hoc signing changes the app's Keychain identity on every build.
*Done when:* clicking the emailed link signs you in and the tokens are in Keychain, not on disk.

**3.4 Wire the session into `RewritePipeline`** · S
The pipeline's token source is already `async`. Add a Keychain-backed `AuthSession` / `SessionStore` (access, refresh and expiry as **one** JSON Keychain item so writes are atomic) that refreshes before expiry and owns `isSignedIn` and sign-out; the menu's "Rewrite" toggle (1.7) reads `isSignedIn`, not a pipeline instance.
Replace `setSessionToken` with a session object.
*Done when:* rewrite uses the stored access token; unit tests still pass.

**3.5 Refresh expiring tokens** · M
Before each request, if the access token expires within 60 s, refresh it via `/auth/v1/token?grant_type=refresh_token`. If refresh fails, mark signed out.
*Done when:* a test with an expired token refreshes once and succeeds; with a revoked refresh token it lands in the signed-out state.

**3.6 Sign in / sign out in the menu** · S
Show the signed-in email and a Sign out item.
*Done when:* sign out clears Keychain and disables the Rewrite toggle.

**3.7 Signed-out fallback** · S
On 401 after a refresh attempt: insert raw, show *"You're signed out. Sign in to keep using rewrite."* (calm, no apology, per the voice guide).
*Done when:* revoking the session in Supabase produces this notice on the next rewrite and dictation still works.

---

## Stage 4 — Billing

**4.1 Stripe test-mode setup** · S · **[YOU]** · *see D4*
Create the Pro product and price, and a test webhook endpoint pointing at the staging Worker.
*Done when:* you have the price ID and test keys set as Worker secrets.

**4.2 `POST /v1/billing/checkout`** · M
Authenticated. Creates or reuses a Stripe customer (saved to `profiles.stripe_customer_id`) and a Checkout Session with `subscription_data.metadata.supabase_user_id`. Returns the URL. (The webhook README flags this as missing.)
*Done when:* completing a test-mode checkout flips your `profiles.tier` to `pro`.

**4.3 Harden the webhook** · M
Return a 5xx if the Supabase write fails so Stripe retries. Tests for bad signature, `active`/`trialing`/`past_due`/`canceled`, and missing metadata.
*Done when:* a test with a failing Supabase mock returns non-2xx; the status-mapping tests pass.

**4.4 `POST /v1/billing/portal`** · S
Returns a Stripe customer portal URL (cancel, update card).
*Done when:* the URL opens the portal for a test customer.

**4.5 `GET /v1/me`** · S
Returns `{ tier, remainingThisMonth }` from the Durable Object counter.
*Done when:* the numbers change after a rewrite.

**4.6 Client tier state** · S
Fetch `/v1/me` on launch and sign-in; cache in memory.
*Done when:* the menu shows Free/Pro correctly after sign-in.

**4.7 "Upgrade to Pro" flow** · M
Menu item opens the checkout URL in the browser; after return, poll `/v1/me` for up to two minutes. Prompt copy verbatim from the voice guide.
*Done when:* upgrading in test mode turns the menu to Pro without restarting the app.

**4.8 "Manage subscription"** · S
Opens the portal URL for Pro users.
*Done when:* it opens the portal.

**4.9 Free-user rewrite handling** · S
When the proxy returns 402: insert raw and show the upgrade prompt, once per session (no nagging).
*Done when:* a Free user with rewrite on sees the prompt once, dictation is unaffected, and a second attempt in the same session shows no prompt.

---

## Stage 5 — Make the trust claims verifiable

**5.1 First-rewrite disclosure** · S
Requirements from the Day 2 security review: the sheet is the *only* caller of `RewriteConsent.recordAcceptance()` (remove its `#if DEBUG` guard deliberately, and keep a separate DEBUG shortcut); write only on an explicit click; Decline as prominent as Accept, and Return must not trigger Accept; record version, timestamp and account; add a revoke control, and revoke on sign-out and on any disclosure-version bump. Consent in a `UserDefaults` plist is a UX gate, not proof: launch arguments and `defaults write` can forge it. Read only the app's own persistent domain at minimum, and prefer a Keychain record bound to the account once a stable signing identity exists. State plainly what is sent and to whom (the transcript text goes to our server and then to Anthropic), and claim only retention and logging behaviour the proxy code proves. Also update `README.md` lines 10 and 132 ("No audio or text ever leaves your machine", "No network requests are made except to download the Whisper model") in the same change: they are false once rewrite can fire.
A one-time sheet before the first rewrite is ever enabled. It says exactly what leaves the device: text only, never audio. Acknowledgement stored in config.
*Done when:* rewrite can't be turned on before the sheet is accepted.

**5.2 Hotkey listener audit** · S
Add a comment and a test in `HotkeyManager` that only key codes are compared and nothing is stored. Reword the public claim to: *"The app watches for your hotkey and ignores every other key. It never records or stores keystrokes."*
*Done when:* `TRUST.md` lists each claim with the file that proves it and a way to check it yourself.

**5.3 Network egress inventory** · S · *see D6*
List every outbound connection in the client (model download, Sparkle appcast, proxy, Supabase auth) in `TRUST.md`. Fix the PRD/site wording where "zero network requests" overstates it.
*Done when:* the inventory matches a `grep` of the sources.

**5.5 Keep dictated text off shared pasteboards** · S
`TextInserter` writes the transcript to the general pasteboard with no marker, so clipboard managers can capture it and Universal Clipboard can sync it. Mark it concealed/transient (`org.nspasteboard.ConcealedType`, `.currentHostOnly` where it applies) and test the insertion still works across the layouts covered today.
*Done when:* a clipboard manager that honours the marker does not record dictations, and paste behaviour is unchanged.

**5.4 No-network dictation test** · M
A script that runs transcription under a network-denying sandbox profile and confirms it still works.
*Done when:* the script passes locally and in CI.

---

## Stage 6 — Brand pass

**6.1 Extract `BrandColor` and add semantic colours** · S
Move it out of `OnboardingWindow.swift`; add success `#3D8168`, danger/error `#C0392B`, warning `#B8860B`, each with light and dark variants.
*Done when:* onboarding still renders identically.

**6.2 Contrast test and token fixes** · M
Unit test computing WCAG ratios for every foreground/background pairing the app uses (4.5:1 text, 3:1 large text and UI). Then adjust the failing tokens from finding 12 (e.g. a lighter emerald for text on dark, darker sage on light) and record the changes in `brand-color-system.md`.
*Done when:* the test passes for all pairings in use. Amber and danger are dormant in v1, so only fix what ships.

**6.3 `Copy.swift`** · S
Move every user-facing string into one file, verbatim from the voice guide's v1 samples.
*Done when:* strings in onboarding are read from it.

**6.4 Copy lint test** · S
A unit test that fails if `Copy.swift` contains "smart", "seamless", "powerful", "magic", "simply", "Oops", or exclamation marks (with a small allow-list).
*Done when:* the test passes, and adding "seamless" to a string makes it fail.

**6.5 Replace ad-hoc strings** · M
Route the remaining error and menu strings through `Copy.swift`.
*Done when:* no user-visible string literal remains in `StatusBarController`, `AppDelegate` or `Permissions`.

**6.6 Appearance check** · S
Screenshot onboarding, sign-in, upgrade and disclosure windows in light and dark, and review against the palette.
*Done when:* screenshots are in `docs/` with no unstyled defaults.

---

## Stage 7 — Growth loop and metrics (PRD P0)

**7.1 Keep the last before/after pair in memory** · S
No disk storage; the pair is dropped on quit.
*Done when:* after a rewrite, the app can produce (raw, rewritten) for the most recent one only.

**7.2 "Copy before/after" menu item** · S
Copies a formatted before/after to the clipboard, with the share-prompt copy from the voice guide.
*Done when:* pasting into a note shows both versions with a plain label.

**7.3 Referral schema** · S · *see D7*
`referrals` table and a per-user code.
*Done when:* every profile has a code.

**7.4 `POST /v1/referral/redeem`** · M
Validates a code and records the pair; rejects self-referral and reuse.
*Done when:* tests cover valid, self, reused and unknown codes.

**7.5 Apply the trial extension** · M
Extend both users' trials through Stripe (coupon or `trial_end`).
*Done when:* both test accounts show the extension in Stripe.

**7.6 Referral UI** · M
"Invite someone" copies a link with your code; a redeem field appears at sign-in. Copy from the voice guide.
*Done when:* a second account redeems a code and both extensions apply.

**7.7 Opt-in diagnostics** · M · *blocked by D5*
Toggle (off by default) sending the five v1 events as anonymous counters via `POST /v1/events`: `dictation_completed`, `rewrite_invoked`, `subscription_tier_changed`, `before_after_shared`, `referral_sent`. The toggle screen lists exactly what is sent.
*Done when:* with the toggle off, no request is made (extend 5.4's test to cover it).

**7.8 Usage dashboard (P1, later)** · L
Needs an on-disk history and a privacy decision first. Don't start until beta feedback asks for it.

---

## Stage 8 — Release pipeline *(finish before beta; needs D1, D6)*

**8.1 Apple Developer Program and Developer ID certificate** · S · **[YOU]** ($99/yr)
*Done when:* the certificate is in your Keychain and a notarization credential profile is stored.

**8.2 Package `whisper-cli` inside the app** · L
Build whisper.cpp (Metal) in a script, place it at `Contents/Resources/whisper/whisper-cli` (the path `Transcriber` already checks), and confirm no Homebrew dylib dependencies. Also check whether `bundle-app.sh` embeds `Sparkle.framework` and fix it if not.
*Done when:* the app transcribes on a Mac (or user account) with no Homebrew `whisper-cpp`, and `otool -L` shows only system libraries plus the embedded frameworks.

**8.3 Bundle the default model** · M · *see D6*
Look for the model in the bundle before downloading.
*Done when:* on a machine with networking disabled, a fresh install dictates on first launch.

**8.4 Sign inside-out with the hardened runtime** · M
Sign helper binaries and frameworks first, then the app, with entitlements for microphone input.
*Done when:* `codesign --verify --deep --strict` passes and the app records audio.

**8.5 Notarize and staple** · M
`scripts/notarize.sh` using `notarytool`.
*Done when:* `spctl -a -vv` reports "accepted, source=Notarized Developer ID" on a clean Mac.

**8.6 DMG** · S
Build, sign, notarize and staple.
*Done when:* dragging the app out of the DMG launches with no Gatekeeper warning.

**8.7 Sparkle keys and wiring** · S
Run `generate_keys`, put `SUPublicEDKey` and `SUFeedURL` in the plist, call `UpdaterController.shared.start()` from `AppDelegate`, add "Check for Updates…" to the menu. Back up the private key somewhere that isn't the repo.
*Done when:* the menu item runs a check against the feed.

**8.8 Appcast generation and hosting** · S
`generate_appcast`, hosted on the existing Cloudflare Pages site.
*Done when:* the appcast URL serves valid XML.

**8.9 Prove Sparkle rejects an unsigned update** · S
Serve an unsigned or wrongly signed build through the appcast and confirm the app refuses it (TRD Section 11).
*Done when:* the procedure and its result are recorded in `scripts/`.

**8.10 Release workflow** · M
A GitHub Action that, on a version tag, builds, signs, notarizes, makes the DMG, updates the appcast and uploads the release. Reconcile with the existing `ship` skill and `deploy.yml`.
*Done when:* a tag produces a downloadable, notarized DMG without touching your laptop.

**8.11 Decide the fate of the Homebrew path** · S
Also: `llms.txt` still says "Apple Silicon and Intel" (wrong; Intel isn't supported) and the site still promotes the upstream install. `NOTICE` texts were verified against upstream on 2026-09-24; re-check when whisper.cpp is bundled (Task 8.2).
`Formula/open-wispr.rb` still targets upstream v0.9.1. Retarget it or retire it in favour of the DMG.
*Done when:* README's install section has a single, working recommended route.

---

## Stage 9 — Beta (TRD Phase 3)

**9.1 Fresh-machine acceptance pass** · S
On a clean macOS user account: install the DMG, walk onboarding, grant both permissions, dictate, sign in, upgrade (test mode), rewrite, sleep and wake, update.
*Done when:* every step passes and any failure has a filed task.

**9.2 In-app "Send feedback"** · S
Menu item opens a prefilled email or form.
*Done when:* it opens with the version number included.

**9.3 Legal pages** · M · **[YOU]**
Privacy policy and terms of service, linked from the app and site. Required before real payments.
*Done when:* both are live and linked.

**9.4 Switch Stripe to live mode** · S · **[YOU]**
*Done when:* one real low-value purchase and refund complete end to end.

**9.5 Invite 10–20 non-founder users** · S · **[YOU]**
Include at least one person who dictates out of necessity (the PRD's accessibility segment).
*Done when:* invites are sent and each recipient has a way to reach you.

**9.6 Decide the rewrite trigger** · S · *see D3*
Use what beta users actually did. If a second hotkey wins, add a `rewriteHotkey` config option as its own task.
*Done when:* the TRD open question is answered in writing.

**9.7 30-day checkpoint** · S
Review against PRD Goal 2 and the Path-to-v2 gate (Section 13).
*Done when:* you can state whether a non-founder user is paying, and what the gate says.

---

## Stage 10 — Public launch (TRD Phase 4)

**10.1 New landing page copy** · M
The current `index.html` is open-wispr's. Rewrite in the brand voice, scoped honestly to v1 (no agent teasers).
*Done when:* the page describes what the product does today and links to the DMG.

**10.2 "Wispr Flow alternative" page (P1)** · M
*Done when:* the page is live and indexed.

**10.3 Launch post** · S
Show HN or equivalent.
*Done when:* posted.

---

## Stage C: Context and Screen Awareness ("Ask" and "Edit selection"; option B)

*Added 2026-09-25 at the founder's request. Not yet given a slot in `murmur-30-day-schedule.md`; placement is a founder decision (see the note at the end of this stage). Read-only first: these features show an answer or replace text the user selected; they never click, send or run anything. The action-taking agent (Email/Calendar, tasks A1-A20) is separate.*

**The idea, in three levels (the "context ladder"; cheapest first, screenshot only when needed):**
1. **Level 1, no screenshot:** which app and window is in front, the text the user has selected, what kind of field the cursor is in. Read through the Accessibility permission the app already has. Cheap, private, works offline until the AI call.
2. **Level 2, screenshot on demand:** one screenshot, taken only when the user presses the Ask hotkey (needs the Screen Recording permission), kept in memory only, never stored.
3. **Level 3, vision AI:** the screenshot plus the spoken question go through our proxy to a vision model, and the answer is shown in a small floating overlay.

**Design rules (from the PRD's trust commitments, the Day 2 review and the ChatGPT analysis):** a separate hotkey (dictation stays exactly as it is); capture only on that hotkey, never in the background; a separate consent record that says exactly what is sent (selected text, window title, screenshot); password and secure fields excluded; the answer is displayed (not pasted) so a manipulated reply cannot type into another app; no storage of screenshots or answers on our servers; cost-controlled with its own quota because vision calls cost more than text. HeyClicky already ships this idea, so the aim is not to match its feature list but to be the private, local-first, cheaper version.

**C0 Read the open-source references and decide what to reuse** · S  **[DONE 2026-09-25: result in `docs/c0-decision.md`: reuse ideas, copy no code; Fazm has no licence file and is off limits; write our own accessibility wrapper]**
Read `farzaa/clicky` (MIT; same Swift-plus-Cloudflare-Worker shape as ours) and Fazm (MIT per third parties: verify the LICENSE file), plus AXSwift as the accessibility reference. Output: a one-page decision in `docs/open-source-landscape.md` (what we reuse, what we rewrite, and why), borrowed pieces listed in `NOTICE`, and a security-engineer review of anything copied (their code sends audio to AssemblyAI and audio replies to ElevenLabs, which we will not use). Details and licence findings: `docs/open-source-landscape.md`.
*Done when:* the decision page exists, both LICENSE files were read, and no code is copied without a `NOTICE` entry.

**C1 `ContextSnapshot` type, redaction rules and default excluded apps** · S
Add a default excluded-apps list here (password managers, Keychain Access), not at C12. A small value type (`app`, `windowTitle`, `focusedRole`, `selectedText`, size caps, `isSecureField`), a `redacted()` function, and tests. No collection code yet.
*Done when:* tests prove secure fields never yield text and every field has a hard size cap.

**C2 Level-1 context collector** · M
Read the frontmost app, window title, focused element role and selected text through Accessibility (`AXUIElement`), off the main thread with a short timeout. Detect and exclude secure text fields. Report per-app quality honestly (Electron apps and browsers expose less). No clipboard tricks in this task.
*Done when:* on TextEdit, Notes and Safari the snapshot shows the right app, window and selected text; on a password field it returns nothing; unit tests cover the pure parts.

**C3 "Edit selection" by voice** · L, now split into **C3a** (`/v1/edit` backend, a rewrite clone, M) and **C3b** (second hotkey, focus-checked replace, undo, M). It cannot ship before the text consent in C6, which now comes first.
Second hotkey: speak an instruction ("make this shorter"), the selected text and the instruction go through the same gate and consent as rewrite to a new `/v1/edit` proxy endpoint, and the result replaces the selection using the existing ordered, focus-checked insertion path. Cmd+Z must undo it.
*Done when:* select a sentence, say "make this more professional", the selection is replaced; with the proxy down the selection is left untouched and a notice says so.

**C4 Screenshot on hotkey** · M
ScreenCaptureKit single shot behind one narrow API callable only from the Ask hotkey path; Screen Recording permission with a plain-language explainer before the system prompt; the single-shot API needs macOS 14 as far as I know (verify; the whole feature is hidden on macOS 13). *Shared with A4 and A5: build once.*
*Done when:* pressing the hotkey captures exactly one image, and nothing is captured at any other time (test that no other code path can call it).

**C5 Image handling and on-device OCR** · M, split into **C5a** (downscale, encode, memory-only proof, S) and **C5b** (Vision OCR, M)
Downscale, re-encode, keep in memory only, release after the request; never written to disk or logs. Add on-device text recognition with Apple's Vision framework (`VNRecognizeTextRequest`) so most questions can be answered by sending the recognised **text** instead of the image ("text first, pixels last": less private data leaves the Mac, and a text call costs far less than a vision call). The screenshot itself is sent only when the question needs it.
*Done when:* a test proves the image bytes are released and no file is created, and a sample question about an error message is answered from OCR text alone with no image sent.
*Done when:* a test proves the image bytes are released and no file is created.

**C6 Consent records for context data (do this before C3)** · M
Two separate consent records, one per data type, neither reusing the rewrite key: `contextText` (selected text and window title; needed for Edit selection, no screen permission) and `screenImage` (needed only for screenshots). A separate consent record (not the rewrite one), a disclosure that lists exactly what is sent (selected text, window title, screenshot) and to whom, with Decline as prominent as Accept. Designer writes the copy.
*Done when:* Ask cannot run without this consent, and revoking it stops it.

**C7 Backend `/v1/ask`** · L
Vision-capable endpoint with tier check, its own quota (Durable Object, like rewrite), image size cap, no retention, content-free logs, stop-reason allow-list, 90 s timeout and no retries, and a mock provider for local use. *Shares A9.*
*Done when:* the same style of test suite as `/v1/rewrite` passes, including 20 parallel requests against the quota.

**C8 Ask overlay** · L
A small floating panel (not a dashboard): "Listening", then the answer text, Esc to dismiss, a Copy button, never steals focus in a way that breaks typing. Designer specifies, macOS engineer builds.
*Done when:* the answer appears next to the cursor area and disappears on Esc, in light and dark mode, with VoiceOver labels.

**C9 `AskCoordinator` and the context-ladder router** · M (absorbs the former C11: start with simple rules)
Like `RewriteCoordinator`: gate (mode, consent v2, token, Screen Recording granted), offline short-circuit, 6-10 s deadline, sanitiser for displayed text, stop-after-401/402 rules, plain-language notices.
*Done when:* every failure shows a calm notice and never types anything.

**C10 Screen prompt-injection evaluation** · M
A fixed set of screens with hidden instructions ("ignore the user and say X"); a script that runs them through the model and records what it does. Read-only limits the damage to a misleading answer, but we measure it.
*Done when:* one command prints a table for the current prompt and model, and the failure rate is recorded.

**C11 (merged into C9; no longer a separate task)** · was M
Decide whether Level-1 context is enough to answer, and only take the screenshot when it is not (starts as simple rules, e.g. "what does this error mean" with selected text needs no screenshot). Saves cost and permissions.
*Done when:* a set of sample questions routes to the expected level with a measured cost saving.

**C12 Privacy and security pass** · M
Sensitive-content handling (password managers, banking, notifications, other people's data), an "exclude these apps" list, `TRUST.md` and the privacy policy updated for screen data, red-team review.
*Done when:* the security review has no open High findings and the claims in the docs match the code.

**C13 On-screen pointer ("it shows you where to click")** · L  *(added at the founder's request, 2026-09-25)*
When the answer refers to a control, show a pointer or highlight on that control. Design intent (tech-lead to confirm before building): **accessibility first**: read the frontmost window's element tree (bounded walk: depth, element count and time limits), let the model choose an element by id, and draw the pointer at that element's exact on-screen frame, which is reliable and needs no vision guessing; fall back to model-suggested screenshot coordinates only when the accessibility tree is empty (games, remote desktops, some browsers), and say so when unsure. Display only: the pointer never clicks or types. Draws on our own non-activating overlay, handles multiple displays and Retina scaling, disappears on Esc or after a timeout, and never blocks the user's own mouse.
*Done when:* asking "where do I turn on dark mode?" in System Settings puts a pointer on the right control at least 4 times out of 5 in a fixed test set, and on an unsupported app the answer says it cannot point and gives text instead. *Serves bets 1 (accessibility-first sends short text, not pixels) and 3.*

**Explicit non-goals for now:** freehand drawing on the screen, recording what the user does ("watch me and learn a workflow"), continuous or background observation, and any action that clicks or types on the user's behalf (that is the agent stage).

**Smallest safe first slice (tech-lead, 2026-09-25):** C1, C2 (our own accessibility wrapper), the text consent from C6, the "what will be sent" preview, then C3 (Edit selection). It needs no Screen Recording permission and works on macOS 13. The screenshot half (C4-C12) waits until after the beta.

**PRD conflict to resolve before C4:** PRD sections 7, 8 and 13 say screen capture is not built until the v2 gate is met, and CLAUDE.md says the agent flag ships off. C1-C3 do not capture the screen; C4 onwards does. The founder must confirm the scope change in writing and the PRD must be edited first. Ask ships behind a default-off flag.

**Placement decision for the founder:** (a) after A (Email/Calendar), i.e. after Day 30; (b) replace A in Days 19-30, because C4/C5/C7 overlap A4/A5/A9 and Ask needs no Google approval; (c) a light slice earlier: C1-C3 (Level-1 context and Edit selection) need no screen permission and could ship around Days 8-10, with the screenshot half (C4-C12) after the beta. My recommendation is (c) then (b); the tech-lead persona has not reviewed this placement yet.

## Not in this plan

Everything in PRD/TRD Section 8 (agent layer, screen capture, OAuth handlers, Terminal Handler), Windows, custom vocabulary, encrypted sync, bring-your-own-key mode. These wait for the Section 13 gate.

## Suggested first three tasks

1. **0.1** (get tests running), because every Swift task afterwards depends on it.
2. **1.1** (typed, testable rewrite errors), the smallest real code change.
3. **D1** (the name), which costs nothing to start thinking about and is the most expensive thing to change late.
