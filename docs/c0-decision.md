# C0 decision: what we reuse from the open-source references

*Tech-lead review, 2026-09-25. Shallow clones read in a scratch folder; nothing was built or run; runtime behaviour of the reference apps is **not verified**. File paths below are inside the clones. Verdict: **reuse ideas, copy no code by default.** Only `clicky` is legally and architecturally usable, and even there the useful parts are small.*

## 1. Licence check (LICENSE files read, not READMEs)

| Repo | Result | Red flags |
|---|---|---|
| **farzaa/clicky** | `MIT License, Copyright (c) 2026 Farza`. Last commit 2026-04-27 (README only; the repo is frozen and the README says new work is private). | Info.plist points its update feed at someone else's repo; a hard-coded analytics key; Swift 5 mode; sandbox off. |
| **Fazm** (mediar-ai/fazm) | **No LICENSE file.** The README says only "MIT" with no holder or text; the one LICENSE in the tree is a vendored library (BSD-3). **Treat as unlicensed: read for ideas only, never copy.** | **Contradicts our bets 1 and 2 and my earlier write-up:** "WhisperKit" appears nowhere (it uses Deepgram cloud speech-to-text); it pulls PostHog, Sentry, Firebase and session replay; a recorder captures the full display at 5 fps and can upload it to cloud storage behind a feature flag; its Info.plist says screen recording is to "monitor your focus". |
| **AXSwift** | `MIT, Copyright (c) 2017 Tyler Mandry`. Last commit 2021-01-26 (about 5.7 years stale). | `fatalError` paths in a menu-bar context; 6 s default accessibility timeout. |
| **Peekaboo** | `MIT, Copyright (c) 2025 Peter Steinberger`. Very active. | Five git submodules whose licences were not read; needs macOS 15+ and a Swift 6.2 toolchain. |

## 2. Reuse table (quality 1 to 5)

| Capability we need | Reference | Quality | Call |
|---|---|---|---|
| Level-1 context read (app, window title, focused element, selected text) | none has real code (clicky only checks permission; AXSwift is a thin wrapper) | 2 | **IGNORE code; write our own** |
| Secure-field exclusion | Peekaboo returns nothing for `AXSecureTextField`; AXSwift has the constant | 3 | **ADAPT and fail closed**: if unreadable, timed out or unknown, return nothing. Also skip when secure event input is on. Whether browsers and Electron expose password fields as `AXSecureTextField` is unverified: C2 must test it. |
| Single-shot screenshot | clicky `CompanionScreenCaptureUtility.swift` (uses `SCScreenshotManager.captureImage`, excludes its own windows, downsamples in the stream config) | 3 | **ADAPT.** It captures all displays; we capture only the display under the cursor or the frontmost window. Peekaboo wraps capture in a 3 s deadline: copy the idea. |
| Screen Recording permission flow | clicky `WindowPositionManager.swift` (prompt once, then open System Settings; small pure function with 3 tests); Peekaboo's preflight-then-probe-then-retry knowledge | 4 | **ADAPT (rewrite is as cheap as copying).** Do **not** copy clicky's probe that takes a real screenshot just to trigger the prompt (a capture before consent) or its "previously granted, so proceed" fallback. |
| Image downscale and encode | clicky (JPEG 0.8, media-type sniffing) | 3 | **ADAPT** with in-memory ImageIO. Run OCR on the higher-resolution capture, separate from the smaller upload copy. **Do not copy Fazm's screenshot code: it writes files to disk and keeps them 30 days.** |
| Overlay that does not steal focus | clicky overlay (non-activating, all spaces, but ignores the mouse, fixed 6 s hide, 60 fps cursor timer); Fazm's `KeyablePanel` pattern (can become key, non-activating) | 3 | **ADAPT.** Our panel does not become key on show; Esc comes from our existing global monitor; it becomes key only when the user clicks Copy; placement by a slow timer. |
| Worker proxy for a vision endpoint | clicky `worker/src/index.ts` | 1 | **IGNORE.** No authentication, the client picks the model and limits, provider errors are echoed and logged, no rate limit or size cap. Our proxy already does better: build `/v1/ask` as a sibling of `/v1/rewrite`. Take only the shape of the image-plus-text request block. |
| Prompt | clicky (spoken-persona text plus coordinate tags, no untrusted-content framing) | 2 | **IGNORE.** Pointing tags and history are non-goals. |
| Hotkey and analytics | clicky uses an event tap that sees every keystroke; Fazm uses Carbon `RegisterEventHotKey`; both send transcripts or replies to analytics | n/a | **IGNORE analytics.** Use our `HotkeyManager`; Carbon hotkeys are an optional idea for the second hotkey. |
| Accessibility tree budget (later) | Peekaboo (depth 12, 1,000 elements, 250 children, deadline) | 4 | ADAPT only if we add a tree read after C2. |

**Unsafe to copy for our bets:** cloud speech or voice services, raw multi-display screenshots sent to a third party, an unauthenticated open relay, any capture before consent, screenshots on disk, transcript or reply telemetry, background recording. Neither app has a sanitiser for displayed model output.

## 3. What we must add (neither project has it)
- **One gate for every new flow** (mode, per-data-type consent, token, macOS version, Screen Recording granted for images, flag off by default), modelled on `RewriteGate` and `RewriteCoordinator`, with the offline short-circuit, a 6 to 10 s deadline, stop-after-401/402 and an untouched fallback on failure.
- **Two consent records, not one:** `contextText` (selected text and window title) and `screenImage`. Edit selection must not require screenshot consent; neither may reuse the rewrite consent key. The debug-only grant rule stays until the disclosure sheet exists.
- **A display sanitiser** for answer text (plain text, length cap, strip control, bidi and invisible characters; reuse the `RewriteSanitizer` character rules, **not** its "shorter than 30% means truncated" rule, which is wrong for answers).
- **Text first, pixels last:** Apple Vision OCR on the Mac; send the image only when the question is about layout or appearance.
- A "what will be sent" preview per data type, our own quota, content-free logs, no telemetry, our own windows excluded from capture.

**Smallest safe first slice:** C1 (context type, plus a default excluded-apps list) and C2 (our own accessibility wrapper), the text consent (from C6) and the preview, then C3 (Edit selection). It needs **no Screen Recording permission** and works on macOS 13. The screenshot half (C4 to C12) comes later.

## 4. Accessibility library: write our own thin wrapper
Do not adopt AXSwift: stale since 2021, `fatalError` paths, a 6 s default timeout (we want about 0.3 s via `AXUIElementSetMessagingTimeout`), 1,466 lines of which we need under 200, and a dependency for a copy-sized need is a supply-chain burden in a trust product. Peekaboo pulls another submodule library with an unread licence. Own wrapper: raw `AXUIElement` calls, off the main thread, per-call timeout, fail closed.

## 5. Effort re-estimate (Stage C)
C0 M to S. C1 S (add the default excluded-apps list here, not at C12). C2 M. **C3 L splits into C3a `/v1/edit` backend (M) and C3b hotkey, focus-checked replace and undo (M); it cannot ship before the text consent.** C4 M (3 s deadline, one display or window, hide on macOS 13, add the Screen Recording usage string). **C5 splits into C5a downscale/encode/memory-only (S) and C5b Vision OCR (M).** **C6 (consent, per data type) moves before C3.** C7 L. C8 L (only the panel pattern is reused). **C9 M absorbs C11 (router, simple rules first).** C10 M. C12 M.

## 6. Risks and conflicts to resolve
- **PRD conflict:** PRD sections 7, 8 and 13 say screen capture is not built until the v2 gate is met, and `CLAUDE.md` says the agent flag ships off. Stage C puts screen capture in the v1 codebase. **The founder must confirm the scope change and the PRD must be edited before C4** (C1 to C3 do not capture the screen). Ship Ask behind a default-off flag.
- **macOS version:** the single-screenshot API needs macOS 14 (one reference marks it 14.0, another 14.2; not pinned down). Hide screenshot Ask on macOS 13; Level-1 context and Edit selection stay on 13.
- **Screen Recording quirks:** the preflight check can give false negatives; the accessibility permission cache reportedly goes stale on macOS 26 (per Fazm); grant-needs-restart and re-approval prompts are known but unverified here. Our build is ad-hoc signed, so the permission grant is tied to the signature and will not survive rebuilds: a stable Developer ID (Stage 8) is needed.
- **Entitlements:** `scripts/bundle-app.sh` has no screen-capture usage string yet; confirm in a signed, notarized build. Not verified.
- **Not verified at all:** runtime behaviour of any reference app; Fazm's accessibility and agent code (it lives in an external tool not in the repo); the Peekaboo submodule licences.

## 7. NOTICE snippet (only if code is copied; the default is no copy)
Portions adapted from Clicky (https://github.com/farzaa/clicky), Copyright (c) 2026 Farza, MIT License. Copied part: <name the file and function>. The full licence text is kept at `third_party/clicky/LICENSE`. Ideas from AXSwift (MIT, Tyler Mandry) and Peekaboo (MIT, Peter Steinberger) were studied; no code copied. Nothing is taken from Fazm (no licence file).
