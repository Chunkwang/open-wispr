# Architecture map (v1)

Maps each component in `murmur-trd.md` to the file that implements it today, and says what is not built yet. Update it when a task changes the picture. "Built" means the code exists in the repo, not that it is deployed.

## Client (Swift, `Sources/`, `Tests/OpenWisprTests/`)

| TRD component | Files | Status |
|---|---|---|
| Hotkey capture (push-to-talk or toggle) | `HotkeyManager.swift` (global `NSEvent` monitor for keyDown, keyUp and flagsChanged; reads the key code and modifier flags, acts only on the configured hotkey, stores nothing), `RecordingLifecycle.swift` (key-down/key-up state machine incl. sleep/wake), `KeyCodes.swift` | Built (inherited) |
| Audio capture | `AudioRecorder.swift`, `AudioDeviceManager.swift`, `RecordingStore.swift` (temp/optional stored recordings) | Built (inherited) |
| Local transcription | `Transcriber.swift` (runs `whisper-cli` as a subprocess; looks for a bundled `whisper/whisper-cli` first, then Homebrew), `ModelDownloader.swift` (downloads a GGML model over the network on first run), `TextPostProcessor.swift` (spoken punctuation) | Built (inherited). **Not self-contained yet:** needs Homebrew `whisper-cpp` and a network download (Tasks 8.2, 8.3) |
| Text insertion at cursor | `TextInserter.swift` (clipboard + synthetic Cmd+V via `CGEvent`, then restores the old clipboard). **The TRD says AXUIElement; the code does not use it.** Accessibility permission is still required to post the paste | Built (inherited) |
| Orchestration | `AppDelegate.swift` (setup, permissions, hotkey → record → transcribe → hand the transcript to the rewrite coordinator and the dictation sequencer → insert, sleep/wake; also `AppDictationEnvironment`, the real frontmost-app, clipboard, status-bar and recording-state hooks behind the sequencer), `Sources/OpenWispr/main.swift` (CLI: `start`, `set-hotkey`, `set-model`, `status`, …), `AppBundleLaunch.swift` | Built |
| Menu bar UI | `StatusBarController.swift` (states: idle, recording, transcribing, **rewriting**, downloading, waitingForPermission, copiedToClipboard, **notice(String)**, error). The Rewrite toggle, its status line and the dev token/consent items exist **only in DEBUG builds** until the disclosure sheet (Task 5.1) | Built. No sign-in or Pro UI yet |
| Permissions | `Permissions.swift` (microphone, Accessibility, upgrade reset) | Built (inherited) |
| Onboarding | `OnboardingWindow.swift` (welcome, microphone, accessibility; brand-voice copy; `BrandColor` tokens live here for now) | Built (Task 6.1 moves the tokens) |
| Config | `Config.swift` (`~/.config/open-wispr/config.json`; new `rewriteMode` = `off`/`auto`, unknown values fall back to `off`) | Built |
| Product identity | `ProductInfo.swift` (display name, bundle name/ID, minimum macOS); `scripts/bundle-app.sh` must match, enforced by `ProductInfoTests` | Built |
| Rewrite client (Pro) | `RewritePipeline.swift` (**internal**; `async`, returns `Result<String, RewriteError>`, never throws; hard total deadline, default 6 s; cancellable; injectable session/token source/base URL; sends `{transcript}` only; ephemeral session, no redirects, no cookies or cache; proxy URL override honoured in DEBUG builds only; default host is the unresolvable `proxy.invalid` until the Worker exists). A test fails if it is constructed anywhere but the coordinator | Built. Tests written and passing on a local XCTest stand-in (real `swift test` needs Xcode, Task 0.1; CI runs it on PRs) |
| Rewrite gate and consent | `RewriteGate.swift`: `shouldRewrite` is true only for mode `.auto` **and** consent for the current disclosure version **and** a session token. Consent is a `UserDefaults` integer outside `config.json`; `recordAcceptance()` exists only under `#if DEBUG`, and CI fails if a release binary contains it. **Consent in a plist is a UX gate, not proof** (Task 5.1 hardens it) | Built |
| Rewrite orchestration | `RewriteCoordinator.swift` (gate → offline check → pipeline → sanitizer → outcome `{text, notice}`; after a 401/402 it stops attempting for the session so known-rejected text is not re-uploaded), `NetworkReachability.swift` (`NWPathMonitor`, waits up to 0.3 s for its first update; unknown counts as online), `RewriteSanitizer.swift` (treats the proxy reply as untrusted: length and truncation limits, strips control, bidi and invisible format characters, collapses newlines), `RewriteNotices.swift` (`RewriteError` → user notice, one place, lint-tested) | Built. `AppDelegate` wiring and the real `NWPathMonitor` are compile-checked only |
| Ordered insertion | `DictationSequencer.swift`: dictation N inserts only after N-1; never while the hotkey is held or a recording is active; never into a different app than the one that was frontmost when the text was ready (the text goes to the clipboard with a notice instead); 8 s watchdog; the gate-closed path with nothing pending inserts immediately, as before Day 2 | Built. Unit-tested; the real environment is compile-checked only |
| Secure storage | `Keychain.swift` (session token today; access + refresh + expiry from Task 3.3) | Built (single token only) |
| Auto-update | `UpdaterController.swift` (Sparkle wrapper) | Built, **not wired in**, no keys or feed (Tasks 8.7, 8.8) |
| Sign-in, billing UI, upgrade prompts | none | Not built (Stages 3–4) |
| v2 agent layer (`Sources/OpenWisprLib/Agent/`) | none | Not built; gated (PRD Section 13, schedule Days 19–28) |

## Backend (`backend/proxy/`, Cloudflare Worker, TypeScript)

| TRD component | Files | Status |
|---|---|---|
| Router + rewrite handler | `src/index.ts` (`POST /v1/rewrite`, `POST /v1/stripe/webhook`; check order: host guard, auth, body (64 KB and 16,000-character caps, whitespace-only and bad UTF-8 rejected), tier, quota, provider; JSON errors 400/401/402/413/429/502, 503 `service_unavailable` when the tier or quota lookup fails or hangs, 500 `misconfigured`/`internal_error` with fixed bodies; one content-free log line per request) | Built, never deployed |
| Mock LLM (dev only) | `src/llmProvider.ts`: `chooseProvider` returns the mock only when `LLM_PROVIDER=mock` **and** the request host is `127.0.0.1` or `localhost`; otherwise the real Claude path. `LLM_PROVIDER` is not in `wrangler.toml` (CI fails if it appears) | Built |
| Auth (Supabase JWT, HS256 shared secret) | `src/auth.ts` (requires `exp`, a UUID `sub`, `aud=authenticated`, and `iss=${SUPABASE_URL}/auth/v1`), `src/supabaseUrl.ts` (one place that normalises the URL) | Built. Algorithm to be confirmed against the real project (Task 2.3) |
| Deployment safety guard | `src/hostGuard.ts`: off a loopback host the Worker refuses example/weak secrets (`local-dev-*`, under 32 characters, the webhook placeholders) with a fixed `misconfigured` body | Built |
| Tier lookup (Supabase `profiles`) | `src/tier.ts` (a failed lookup throws `TierLookupError`; it is never treated as Free; 3 s timeout) | Built. No migration or RLS in the repo yet (Task 2.2) |
| Server-side quota | `src/quotaCounter.ts` (`QuotaCounter` Durable Object, one per user; one uninterruptible read-check-increment; stores counts only), `src/rateLimit.ts` (calls it with a 3 s deadline), limits in `src/types.ts` | Built and tested with a real Durable Object in local workerd: 20 parallel requests with a limit of 5 admit exactly 5. Not yet run on Cloudflare. Quota counts attempts (a 502 is not refunded) |
| Claude call + rewrite prompt | `src/claude.ts` (90 s timeout, no automatic retries; only `end_turn`/`stop_sequence` with non-empty text count as success, anything else is a 502) | Built. Model and prompt not yet chosen by measurement (Tasks 2.8, 2.9) |
| Stripe webhook → tier | `src/stripeWebhook.ts` | Built. Returns 200 even if the Supabase write fails (Task 4.3) |
| Local dev token and mocks | `scripts/mint-dev-token.mjs` (`npm run dev:token`), `scripts/mock-supabase.mjs` (`npm run dev:mock`; `MOCK_TIER`, `MOCK_FAIL`). Steps for running everything without accounts: `docs/local-dev.md` and `backend/proxy/README.md` | Built |
| Checkout / portal / `/v1/me` / referral / events | none | Not built (Stages 4, 7) |
| Tests | `test/*.test.ts` (vitest in real workerd via `@cloudflare/vitest-pool-workers`; 175 tests: contract, hardening, logging, quota); `npm test` | Built. Backend mutation-checked (about 50 deliberate breaks, all caught) |

## Build, packaging, release (`scripts/`, `.github/workflows/`, `Formula/`)

| Concern | Files | Status |
|---|---|---|
| App bundle + Info.plist | `scripts/bundle-app.sh` (copies the binary only, ad-hoc signs, min OS 13.0) | Built; not release-grade (Stage 8) |
| CI | `.github/workflows/ci.yml` (macOS 15: build plus a check that a release binary cannot grant rewrite consent, `swift test`, install smoke test, transcription test; ubuntu: `backend` job with `npm ci`, typecheck, tests, and a guard that `LLM_PROVIDER` is not in `wrangler.toml`) | Built. The `backend` job has not run on GitHub yet (runs on pull requests to `main`) |
| Site deploy | `.github/workflows/deploy.yml` (Cloudflare Pages: `index.html` etc.) | Built; site still describes open-wispr |
| Homebrew distribution | `Formula/open-wispr.rb` (points at upstream `human37/open-wispr` v0.9.1) | Stale (Task 8.11) |

## Where data goes today

- **Dictation:** microphone → temporary WAV → local `whisper-cli` → text → pasted at the cursor. Audio is deleted unless `maxRecordings` > 0. No network, except downloading a model the first time each model size is used.
- **Rewrite (wired, off by default, cannot be enabled in a release build until Task 5.1):** only if mode is `auto`, consent is recorded and a token exists, transcript text → `POST /v1/rewrite` with the Keychain session token → proxy → Claude → sanitised text back. Audio never leaves the device. On any failure the raw transcript is inserted and a notice is shown.
- **Other outbound connections:** model download (`ModelDownloader.swift`); Sparkle appcast once wired. The full inventory goes in `TRUST.md` (Task 5.3).
