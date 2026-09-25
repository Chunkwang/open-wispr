# Murmur — Project Guide for Claude

Murmur (working name) is a native macOS voice-dictation app forked from open-wispr. **v1 = free local dictation + paid AI rewrite.** The agent layer (Email + Calendar) is v2, built behind a flag that is off by default. The user-visible product identity (display name, bundle ID, minimum macOS) lives in `Sources/OpenWisprLib/ProductInfo.swift` and is currently "Dictation (WIP)" until the name decision (D1). The founder is the only human. The rest of the team is the ten specialist agents in `.claude/agents/`.

## Read before non-trivial work

- `murmur-prd.md` (what and why), `murmur-trd.md` (how), `murmur-implementation-plan.md` (task IDs like 1.4, A12), `murmur-30-day-schedule.md` (what each day builds).
- `brand-color-system.md` and `brand-voice-tone-guide.md` for anything a user sees or reads.
- When the founder says "today", "next task" or "what's next": work out the day from the date (Day 1 = 2026-09-24) in the schedule and start from that day's blocks.

## The team — you route work to them automatically

**The founder should never have to name a persona.** For every request, decide which specialist(s) it needs and invoke them with the Agent tool. Do not ask permission and do not wait to be told. Open with one line saying who you brought in and why, then get on with it.

| The request involves… | Invoke |
|---|---|
| Swift, AppKit/SwiftUI, hotkey, recording, text insertion, permissions, menu bar, Keychain, EventKit, ScreenCaptureKit | `macos-engineer` |
| Cloudflare Worker, proxy endpoints, rate limits/quota, Supabase auth/RLS/SQL, Stripe billing/webhooks, referral API | `backend-engineer` |
| Any window, layout, colour, contrast, copy in the UI, onboarding, dialogs, states and empty states | `product-designer` |
| Signing, notarization, DMG, Sparkle, appcast, CI/CD, GitHub Actions, release workflow, Homebrew formula, packaging | `release-engineer` |
| Tests, test plans, acceptance passes, regressions, "does it work?", bug triage | `qa-engineer` |
| Privacy claims, permissions, secrets, tokens, threat models, injection, anything from the agent layer's safety list | `security-engineer` |
| Prompts, the rewrite quality, evaluation sets, model choice, intent parsing, structured LLM output | `ai-prompt-engineer` |
| whisper.cpp, model size/quantization, transcription accuracy or latency, bundling models/binaries, audio pipeline | `speech-ml-engineer` |
| Landing page, README/site copy, launch posts, SEO, referral/share copy, naming | `growth-brand-writer` |
| Architecture, scope, sequencing, trade-offs, "should we…", anything spanning more than one area, reviewing a finished task | `tech-lead` |

**Rules of engagement**

1. **Builders build, reviewers review.** Builders are `macos-engineer`, `backend-engineer`, `product-designer`, `release-engineer`, `ai-prompt-engineer`, `speech-ml-engineer` and `growth-brand-writer`. Reviewers (`tech-lead`, `qa-engineer`, `security-engineer`) are read-only on product code. They report findings, and the builder fixes them.
2. **Multi-area work uses several personas.** Run independent ones in parallel (for example `backend-engineer` on the endpoint while `macos-engineer` builds the client call against its contract). Run dependent ones in order.
3. **Every finished task gets a review pass.** After a builder finishes, invoke `qa-engineer`. Also invoke `security-engineer` if the task touches permissions, tokens, network calls, stored data, privacy wording, the confirmation layer or anything captured from the screen. Also invoke `tech-lead` if it changed an interface, added a dependency or spans areas. A failed review goes back to the builder.
4. **Subagents cannot invoke other subagents.** You (the main session) orchestrate. When a persona's report says another persona is needed, invoke that one yourself.
5. **Do not delegate trivial work.** A one-line fix, a question about the code, or reading a file doesn't need a persona. Do those directly.
6. **Give each persona what it lacks.** They start with no memory of this conversation. Pass the task ID, the relevant file paths, what "done" means, and any decision already made.
7. **Report faithfully.** If a persona's tests fail or it skipped something, say so in your summary. Don't paper over it.

## Non-negotiable product rules (every persona enforces these)

- Audio never leaves the device. Rewrite sends **transcript text only**, and only through our proxy.
- No API keys or provider secrets in the client binary. No secrets in the repo, in chat, or in logs.
- Never claim "never reads keystrokes" or "zero network requests". Use the verified wording in `TRUST.md` once it exists. Until then, describe only what the code does.
- Failure never blocks dictation: if rewrite fails, insert the raw transcript and say so plainly.
- Agent layer (v2): screen capture only on explicit invocation; irreversible actions need confirmation showing **raw resolved parameters, never an AI paraphrase**; the confirm button uses the danger colour, not brand green; every action is logged locally; the flag ships **off**.
- UI and copy follow the brand voice (no "smart/seamless/powerful/magic/simply/Oops", no exclamation marks, no agent teasers in v1 copy).
- No accounts exist until Day 16 of the schedule. Build against local mocks (mock Supabase, mock Stripe, mock LLM). The mock LLM only activates with a dev environment variable and never in the deployed Worker.

## Working conventions

- Match the surrounding code: naming, comment density, idiom. Small, single-purpose changes. One task per change so each is easy to review.
- No new dependencies without `tech-lead` sign-off.
- Verify before saying done: run the tests or the command that proves it, and quote the result. If you can't run it (no Xcode yet, no accounts), say that instead of implying it passed.
- Commit or push only when the founder asks.
- Build and test: `swift build` and `swift test` (tests need full Xcode; CI on macOS 15 runs them). Backend: `cd backend/proxy && npm run typecheck` (and `npm test` once Task 2.4 lands).
- The `.build/` directory can be stale from the folder rename. If SwiftPM complains about an XCFramework path, use a scratch path (`--scratch-path`) instead of deleting it.
