# Open-source landscape for screen and context awareness (Stage C)

***Corrected the same day after the C0 code read (`docs/c0-decision.md`): the Fazm row below was wrong and has been fixed; the tech-lead's verdict is "reuse ideas, copy no code".***

*Desk research, 2026-09-25. Licences and facts come from each project's GitHub page as read on that date; nothing was cloned, built or run. Labels: **[Repo]** read on the project's own page; **[Third party]** from an article or search summary; **[Inference]** our reasoning; **[Unverified]** not confirmed. Before any code is copied, the tech-lead and security-engineer read it, the licence file is checked in the repo (not just the README), and the copied part is listed in `NOTICE`.*

## 1. Verdict

There is no ready-made "private screen buddy" to fork. There is one **MIT-licensed reference** with our architecture (clicky: Swift menu-bar app plus a Cloudflare Worker), a few MIT libraries and tools worth studying (AXSwift, Peekaboo), and Apple's own on-device frameworks that give us the privacy edge for free. After the tech-lead read the actual code (`docs/c0-decision.md`) the verdict is **reuse ideas, copy no code by default**: even clicky's Worker is an unauthenticated open relay, and Fazm has no licence file. One popular project (Screenpipe) looks like the obvious choice and is not: it is not MIT and it records everything continuously.

## 2. Candidates

| Project | What it is | Licence | Shape | Use it? |
|---|---|---|---|---|
| **farzaa/clicky** (github.com/farzaa/clicky) | The original HeyClicky client: push-to-talk menu-bar buddy, screenshot plus transcript to Claude, replies spoken, cursor pointing via `[POINT:x,y:label:screenN]` tags. Swift app plus TypeScript Cloudflare Worker proxy. About 7.6k stars, 1.5k forks. Its README says new HeyClicky development is private. [Repo] | **MIT** [Repo] | Whole app (a reference, not a library) | **Read first (Task C0).** Closest match to what we are building. Adapt (do not copy): single-shot capture and the permission-flow ideas, and the non-activating overlay panel pattern. Ignore its Worker (no authentication, no limits) and its cloud speech and voice parts, which are exactly what we do *not* want. |
| **Fazm** (github.com/mediar-ai/fazm) | A voice-controlled macOS agent. **Earlier summary (from articles) said local WhisperKit speech and MIT; the code read showed otherwise:** no LICENSE file (the README only says "MIT" with no holder or text), cloud speech-to-text (Deepgram), PostHog, Sentry, Firebase and session replay, and a recorder that captures the full display at 5 fps and can upload it behind a feature flag. [Repo, read by the tech-lead] | **No licence file: treat as unlicensed** | Whole app | **Read for ideas only; never copy.** Its posture is the opposite of our bets 1 and 2. |
| **AXSwift** (github.com/tmandry/AXSwift) | Thin Swift wrapper over the macOS accessibility C API. 417 stars, SPM/Carthage/CocoaPods. [Repo] | **MIT** [Repo] | Library | **Do not adopt; write our own thin wrapper (C2).** Last commit 2021-01-26 (about 5.7 years stale), `fatalError` paths, a 6 s default timeout, and we need under 200 of its 1,466 lines. [Repo, C0 read] |
| **Peekaboo** (github.com/steipete/Peekaboo) | macOS CLI and MCP server: screenshots, accessibility maps of an app's UI, click/type automation, optional visual Q and A. Swift 6.2, 5.2k stars, very active. [Repo] | **MIT** [Repo] (five submodules with unread licences) | CLI / MCP server / menu-bar app; needs macOS 15+; **not a reusable library** | **Study, do not embed.** Useful ideas: secure-field check, a 3 s capture deadline, permission-probe quirks, and a bounded accessibility-tree walk. |
| **AXorcist** (github.com/steipete/AXorcist, now under openclaw) | Higher-level Swift accessibility wrapper: chainable, fuzzy-matched queries to read, click and inspect UI. [Third party] | [Unverified] | Library | Look at it if AXSwift feels too low level; check licence and activity first. |
| **Screenpipe** (github.com/screenpipe/screenpipe) | Records screen and audio **continuously** to a local database; event-driven capture; accessibility tree first, OCR as fallback; 21.7k stars; Rust and TypeScript. [Repo] | **Screenpipe Commercial License (source-available): personal non-commercial use only; commercial use of the source needs a licence.** (Some search-result snippets call it MIT; the project's own page says otherwise. Treat it as not usable.) [Repo] | App plus REST API | **Do not embed or copy.** Continuous recording also contradicts our design (capture only on the user's hotkey). The *idea* is worth borrowing: read the accessibility tree first, OCR only when that is empty. Ideas are not covered by its licence; code is. |
| **mlx-vlm** (github.com/Blaizzy/mlx-vlm) | Python package to run vision-language models locally on Apple Silicon (Qwen2-VL and Qwen2.5-VL, LLaVA, Moondream, OCR models and 40+ more); includes an OpenAI-compatible local server. 5.5k stars, active. [Repo] | **MIT** [Repo] | Python package plus local server | **Later option, not now.** Would give a fully local "look at my screen" mode (a strong bet 1 story) but needs a Python runtime and large models (memory needs per model not stated), so it does not fit a small Swift app today. Revisit after v1.5 as an optional download. |

## 3. Apple's own frameworks (no dependency, no licence)

- **ScreenCaptureKit**: capture a single window or display. The single-screenshot API needs macOS 14 as far as we know (verify in Task C4); on macOS 13 the feature stays hidden. [Third party and our earlier note]
- **Accessibility (`AXUIElement`)**: read the frontmost app, window title, focused element and selected text. Needs the Accessibility permission the app already asks for. Coverage is uneven in Electron apps and browsers. [Inference]
- **Vision framework OCR (`VNRecognizeTextRequest`)**: recognises text in an image **on the Mac**; "nothing is uploaded". [Third party, Apple docs]
- **Foundation Models framework**: gives Swift apps Apple's on-device language model (about 3 billion parameters, works offline) on macOS 26 and later. It is text-first; whether it accepts images is **[Unverified]**. Because our minimum is macOS 13, this can only ever be an optional path. [Third party, WWDC25 pages]

## 4. The idea this suggests: "text first, pixels last" [Inference]

Most screen questions ("what does this error mean?", "summarise this page") can be answered from **text**: the accessibility tree, the selected text, or OCR of a screenshot done **on the Mac**. Send that text to the model and keep the image on the device. Only send the screenshot itself when the question is about layout or something text cannot describe.

Why it matters for our bets: much less private data leaves the Mac (bet 1: what is sent is short, inspectable text, not pixels of everything on screen); text calls cost far less than vision calls (bet 4); and it works with a small, cheap model. HeyClicky's open client sends the screenshot itself to Claude. This is the concrete form of the "context ladder" in Stage C.

## 5. Recommended path

1. **Task C0 (done 2026-09-25): the tech-lead read the references and decided "reuse ideas, copy no code"**; see `docs/c0-decision.md`. Only clicky is legally and architecturally usable, and even there only small pieces are worth adapting. Nothing may be copied without a `NOTICE` entry and a security-engineer review.
2. **Build on Apple frameworks** for capture, accessibility and OCR. Own thin accessibility wrapper unless C0 says otherwise.
3. **Keep our own gate, consent and sanitiser** (built and tested in Days 2 and 3) around every new data flow; borrowed code never bypasses them.
4. **Do not use** Screenpipe code. Treat Peekaboo and AXorcist as references. Park mlx-vlm and Foundation Models as later options.

## 6. Sources (accessed 2026-09-25)

- https://github.com/farzaa/clicky
- https://github.com/mediar-ai/fazm , https://dev.to/m13v/what-we-learned-building-a-macos-ai-agent-in-swift-screencapturekit-accessibility-apis-async-28fb , https://fazm.ai/blog/fazm-macos-ai-agent-github
- https://github.com/tmandry/AXSwift
- https://github.com/steipete/Peekaboo
- https://github.com/openclaw/AXorcist (also steipete/AXorcist)
- https://github.com/screenpipe/screenpipe
- https://github.com/Blaizzy/mlx-vlm
- https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- https://developer.apple.com/videos/play/wwdc2025/286/ (Foundation Models framework)
