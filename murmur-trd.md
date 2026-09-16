# Murmur — Technical Requirements Document (TRD)

*Companion to `murmur-prd.md`. Scope revised after the Product Red Team Audit: v1 is dictation + rewrite only. The Agent Engine described in Section 3.3/8 is v2 design intent — its safety mechanisms are specified now so they're decided calmly, not built later under launch pressure, but none of it is on the v1 build sequence.*

---

## 1. System Architecture Overview — v1

Murmur v1 is a native macOS client app with a minimal backend — almost the entire product runs on-device; the backend exists only for the pieces that genuinely need to be server-side (AI metering/billing, not user data storage).

**Client (macOS app, Swift/SwiftUI, forked from open-wispr):**
1. **Dictation Engine** (existing, inherited from open-wispr) — hotkey-triggered audio capture, local transcription via whisper.cpp, text injection at cursor via the Accessibility API. Fully local, zero network, unchanged in spirit from the fork.
2. **Rewrite Pipeline** (new — Pro tier) — takes the raw local transcript, sends text only to our backend proxy, gets back AI-polished text, injects it at the cursor.

**That's the complete v1 client.** No screen capture module, no Action Router, no Action Handlers, no third-party OAuth integration exist in the v1 codebase. This isn't a dormant feature-flagged agent layer — it simply isn't built yet, which is a materially smaller attack surface and a much shorter path to shipping.

**Backend (minimal, hosted on Vercel/Cloudflare Workers + Supabase):**
- Auth (Supabase Auth — Sign in with Apple or email magic link)
- Metered API Proxy — the only path to the Claude API; meters usage per user/tier, never exposes a raw API key to the client
- Stripe billing + webhook, tracking subscription tier per user

## 2. Data Flow — v1

**Flow 1 — Free dictation (unchanged from open-wispr):**
Hotkey held → audio captured → transcribed locally by whisper.cpp → text injected at cursor via Accessibility API. No network call at any point.

**Flow 2 — Pro rewrite:**
Raw local transcript → user invokes rewrite (separate hotkey action or auto-on-release if Pro is enabled) → transcript text (never audio) sent to the Metered API Proxy → proxy calls Claude API → polished text returned → injected at cursor, replacing the draft. Disclosed to the user: only text leaves the device for this step.

*(Flow 3 — the agent action flow — is specified in Section 8 as v2 design intent, not part of the v1 build.)*

## 3. Component Breakdown — v1

### 3.1 Dictation Engine (inherited)
No material changes from open-wispr beyond rebranding and any bug fixes found during integration. This is the one component we're not rebuilding — it's already proven.

**Model / update strategy (new — the prior TRD didn't specify this):** ship whisper.cpp's base or small model by default (accuracy/size tradeoff to confirm against open-wispr's own default before launch — don't silently diverge from a choice upstream already validated). Model files are distributed with the app bundle initially, not downloaded on first run, so v1 works fully offline immediately after install with no first-run network dependency. Model updates ship as part of regular app updates via Sparkle, not a separate download-on-demand system — simpler to reason about and test, revisit only if bundle size becomes a real complaint.

### 3.2 Rewrite Pipeline
- Input: raw transcript string.
- Calls the Metered API Proxy (never the Claude API directly from the client — avoids embedding a key in a distributed binary).
- Output: rewritten text, injected via the same Accessibility API path the Dictation Engine already uses.
- Failure mode: if the API call fails or times out, fall back to injecting the raw transcript with a subtle in-app notice, rather than blocking the user's workflow.

### 3.3 Backend
- **Auth**: Supabase Auth.
- **Metered API Proxy**: thin service (Node.js on Cloudflare Workers or Vercel) that authenticates the request, checks tier/quota, calls the Claude API, returns the result, and logs usage for billing/metering purposes only (not content).
  - **Rate limiting — new, previously unspecified.** The prior TRD had no server-side rate limiting at all; UI-level tier gating on the client is not a real control since it's trivially bypassable by anyone calling the proxy directly with a valid token. Enforce hard per-user quotas server-side: a request-per-minute ceiling and a daily/monthly call cap tied to subscription tier, checked in the proxy before the Claude API call is made, not after. This closes the "leaked or shared credential racks up API costs with no cap" risk the audit flagged, and it's cheap to build now versus retrofitting under live abuse later.
- **Billing**: Stripe subscriptions across Free/Pro, webhook updates the user's tier in Supabase.

## 4. Tech Stack — v1

| Layer | Choice | Why |
|---|---|---|
| Client app | Swift / SwiftUI | Matches open-wispr's existing codebase — we inherit working code instead of rewriting |
| Local transcription | whisper.cpp (Metal-accelerated) | Already proven in open-wispr, ~99 languages, zero network |
| Text injection | Accessibility API (AXUIElement) | Standard macOS automation surface, already used by open-wispr |
| Local storage | macOS Keychain (auth tokens only in v1 — no third-party OAuth tokens exist yet) | Keeps sensitive data on-device |
| Backend hosting | Vercel or Cloudflare Workers | Free tier at v1 scale |
| Auth | Supabase Auth | Free, bundled, low setup cost |
| Billing | Stripe | Standard, well-documented subscription support |
| AI | Claude API (text only, for rewrite) | Vision calls are a v2-only cost — not incurred in v1 at all |
| Auto-update | Sparkle (open source) | Standard, trusted macOS app updater |

**Auto-updater integrity — new, previously unspecified.** Confirm Sparkle's update-signature verification (EdDSA signing) is explicitly configured and tested, not assumed on by default. A compromised update channel shipping an unsigned or unverified build is a real risk given how much local trust this app is asking for — this needs to be a checked box before v1 ships, not an assumption.

## 5. Security & Permissions Model — v1

- **macOS permissions requested progressively**: Microphone on first dictation use, Accessibility on first text-injection use — both with a plain-language explanation shown *before* the OS system prompt appears. Two permissions total in v1, not the four-to-six the full agent scope would have required — a materially smaller trust ask for a first-time user.
- **No API keys in the client binary.** All Claude API calls route through the Metered Proxy, authenticated per-user.
- **No keystroke logging, ever, in any component** — a hard product requirement, and one a security-literate user can verify by inspecting the open-source dictation core directly.
- **No default telemetry** beyond opt-in crash reporting.

## 6. Non-Functional Requirements — v1

- **Dictation latency**: near-instant, consistent with whisper.cpp + Metal performance already demonstrated in open-wispr (rough target: under ~1 second for a typical utterance).
- **Rewrite latency**: a few seconds is acceptable — it's a real network round trip.
- **Offline behavior**: dictation must keep working with no connection; rewrite degrades with a clear, honest in-app message rather than failing silently.

## 7. Open Technical Questions — v1

- **[Product/Engineering]** Exact rewrite-trigger UX — separate hotkey action versus auto-on-release for Pro users. Small decision, worth deciding with real usage feedback rather than guessing pre-launch.
- **[Engineering]** Confirm whisper.cpp default model size against open-wispr's own current default before diverging (see 3.1).

## 8. The Agent Engine — v2 Design Intent (Not a v1 Build Item)

*Specified now, deliberately, so the safety architecture is settled before there's launch pressure to cut corners on it. Nothing in this section is scheduled — see Section 9's Path-to-v2 gate. Scope is smaller than the original plan: Email + Calendar Handlers only at first release; Terminal Handler moved behind a separate developer-mode gate rather than shipping to the mainstream product; File Organization Handler cut; Spreadsheet Handler still deferred.*

### 8.1 Architecture (when built)

Added to the client: a **Screen Capture module** (ScreenCaptureKit, triggered only on explicit agent invocation, never continuous or background — a hard requirement, not a config default that could drift), an **Intent Parsing** step (screenshot + transcribed instruction sent to Claude's vision-capable API via the Metered Proxy, returning a structured `{action_type, target_app, parameters}` object), an **Action Router**, two **Action Handlers** (Email, Calendar — see below), a **Confirmation Layer**, and a local **Action Log**.

Third-party OAuth tokens (Gmail, Google Calendar) would be stored in the macOS Keychain on-device, never on the backend — the client talks to provider APIs directly. This preserves the same trust architecture v1 established: the backend never holds a copy of anything beyond metering data.

### 8.2 Data Flow (when built)

Agent hotkey invoked → screen captured via ScreenCaptureKit (only at this moment) + spoken instruction captured and transcribed locally → screenshot + instruction text sent to the Metered API Proxy → Claude API (vision-capable) returns a structured intent → Action Router dispatches to the matching Handler → Handler calls the relevant provider API directly (using the locally-stored OAuth token) → if the action is irreversible, the Confirmation Layer blocks execution until the user explicitly approves, **showing the raw resolved parameters** → on approval, the Handler executes → result written to the local Action Log → user sees the outcome.

### 8.3 Action Handlers (two, at first release)

- **Email Handler** — Gmail API / Microsoft Graph, OAuth token from Keychain, minimum-necessary scope (send-only where the provider allows it rather than full mailbox access). Irreversible: sending. Reversible: drafting without sending. Rate-limited per hour/day server-side regardless of tier, independent of the general API rate limiting in Section 3.3 — this specifically guards against the Email Handler being turned into a spam vector by a compromised or misused account.
- **Calendar Handler** — Google Calendar API / Apple EventKit / Microsoft Graph. Creating/editing an event is treated as irreversible by default (it notifies other people) even though it's technically undoable.

**Explicitly not built in this release, and why:**
- **Terminal Handler** — moved behind a separate, explicit "developer mode" toggle the mainstream user is never prompted to enable. If built, it still requires everything specified below in 8.5 (argument-array execution, sandboxing, adversarial testing) — moving it out of the default product doesn't relax those requirements, it just removes it from an audience that can't safely evaluate a shell-command confirmation dialog.
- **File Organization Handler** — cut, not deferred-with-a-plan. Revisit only if Email + Calendar usage data shows real demand for more.
- **Spreadsheet Handler** — still deferred; cloud-hosted sheets only if ever built (Google Sheets, Excel via Graph), local-file (Numbers, offline Excel) automation explicitly out of scope given how fragile AppleScript UI automation is for this.

### 8.4 Confirmation Layer and Action Log (when built)

**Confirmation Layer** — a UI overlay, not a background permission check: shows what's about to happen before any irreversible action runs, with one hard, new requirement the prior TRD didn't have:

**Confirmation dialogs must show the raw, resolved action parameters — the actual email address, the actual event details — never an AI-paraphrased summary of them.** This is the direct, specific mitigation for the audit's top technical-risk finding: **prompt injection via captured screen content.** Because the agent's intent comes from a vision model reading whatever's on screen, a malicious webpage or phishing email visible at invocation time could contain hidden text crafted to manipulate the model into an unintended action. A paraphrased confirmation ("Sending your message to Sam") can be made to look safe by the same manipulation that produced the bad action; the literal resolved parameters ("Sending to sam-fake-domain@external-host.example, subject: ...") can't lie about what's actually about to happen. This is a hard architectural requirement for the Confirmation Layer, not a copy-polish detail — treat it as a release blocker for whenever v2 ships, the same way the no-keystroke-logging commitment is treated now.

**Action Log schema — new, previously undefined.** The prior TRD said "local SQLite database" with no schema, which the audit correctly flagged as unbuildable-against. Minimum fields: `id`, `timestamp`, `handler_type` (email/calendar/etc.), `status` (proposed / confirmed / executed / failed / cancelled), `raw_parameters` (the literal resolved values shown in the confirmation dialog — kept for audit/debugging, not just displayed once), `outcome` (success message or error detail), `reversible` (bool). This is the structure that later enables both in-app search/filtering and the B2B audit-trail export opportunity flagged in the PRD's Future Considerations, so it's worth getting right the first time rather than retrofitting.

### 8.5 Terminal Handler Safety (if and when built, behind developer mode)

Confirmation alone is a UX safeguard, not a systems one — a compromised or manipulated confirmation still executes with full privileges if there's nothing underneath it. Requirements, if this is ever built:

- **Argument-array execution only, never string-built shell commands.** The prior TRD gestured at "no unsanitized shell interpolation" without specifying the mechanism; this is the mechanism — commands are constructed and executed as an argument array (e.g., `Process` with an `arguments` array in Swift), never by concatenating LLM-derived text into a shell string, which closes the standard command-injection vector.
- **A constrained execution context** (resource and permission limits — not full-privilege subprocess execution) as a second layer beneath the confirmation dialog, so a bypassed or tricked confirmation doesn't equal full system access.
- **Dedicated adversarial security testing** before any release that includes it — deliberately trying to get it to execute something harmful without proper confirmation, including via crafted screen content (see 8.4's prompt-injection mitigation) — not just functional testing.
- Full command text always shown in the confirmation dialog, raw and unparaphrased, before execution — same rule as 8.4, applied to this specific Handler.

### 8.6 OAuth and Recovery (when built)

- **Explicit re-auth flow, designed up front — new emphasis.** OAuth tokens living only in the local Keychain is correct for the trust story, but the prior TRD didn't address what happens when a Mac is lost, reset, or a token is externally revoked (the user revokes Gmail access from Google's side). Without a designed flow, this silently drops every integration with no recovery path and no clear error message. Requirement: a clear, well-copy'd re-auth prompt triggered the moment a provider API call fails on an auth error — not a generic failure message, and not a silent retry loop.
- **Minimum OAuth scopes** per provider (e.g., Gmail send-only rather than full mailbox read/write, where the provider allows it).
- **Provider app review**: Google and Microsoft require review/verification for sensitive scopes like sending email on a user's behalf. This process is outside our control and can take real time — start it early, in parallel with engineering, once v2 is actually greenlit, not after the Email Handler is built.

## 9. Path to v2 — Gate Before Any of Section 8 Is Scheduled

Mirrors the PRD's Section 13 exactly, restated here so the TRD can't drift from it: v2 engineering does not start until v1 has real non-founder users, a measurable Pro conversion rate to model agent-tier unit economics against (vision API calls cost materially more per call than the Pro rewrite's text-only calls — this needs real usage data, not the previous unresearched $40–60/month guess), unprompted user demand signal for more than dictation+rewrite, and an honest read on whether two people can safely build the Terminal Handler's sandboxing and pass OAuth app review without compressing the timeline.

## 10. Build Sequence — v1 Only

- **Phase 1 — Dictation core.** Fork open-wispr, get it rebuilding cleanly under the new name/branding, confirm feature parity with upstream. Fastest phase — integrating working code, not writing a transcription engine.
- **Phase 2 — Pro rewrite.** Stand up the Metered API Proxy (with server-side rate limiting from day one, per Section 3.3 — not retrofitted later), Supabase auth, Stripe billing, and the rewrite call itself. **This is the real launch milestone** — v1 is a complete, sellable product at the end of this phase, and that's the point where the Path-to-v2 clock (Section 9) starts.
- **Phase 3 — Beta and real users.** A real beta period with non-founder users (friends, a relevant subreddit, a Show HN) before or alongside general launch — this phase didn't exist as a distinct, named step before, and it should, since the entire v2 decision depends on what happens here.
- **Phase 4 — Packaging, notarization, public launch.** Apple Developer ID notarization, installer, polish.

**Agent-layer phases (Screen capture/Intent parsing foundation → Email+Calendar Handlers → optional developer-mode Terminal Handler with dedicated security testing → packaging) only begin once Section 9's gate is met — not sequenced here as committed phases, since committing a timeline to unbuilt, ungated work is exactly the mistake this revision is correcting.**

## 11. Testing Strategy — v1

- Dictation accuracy: reuse or extend open-wispr's existing test approach where one exists.
- Rewrite quality: a fixed evaluation set of sample raw transcripts, spot-checked for quality regressions as prompts change.
- Rate-limit and quota enforcement: verify the Metered Proxy actually rejects over-quota requests server-side, not just that the client UI hides the option.
- Auto-updater: verify Sparkle signature verification actively rejects an unsigned test build, not just that it's configured.

*(Agent dry-run testing, Terminal Handler adversarial security review, and prompt-injection-specific confirmation testing are specified in Section 8 as v2 requirements — they apply the moment that work is greenlit, not before.)*
