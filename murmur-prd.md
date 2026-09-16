# Murmur — Product Requirements Document

*Working name "Murmur" (placeholder) throughout — easy to swap later.*

*Revised after the Step-by-step Product Red Team Audit (`product-red-team-audit.md`). The single biggest change: the agent layer is no longer part of v1. This document now describes a real, shippable, revenue-generating v1 (dictation + rewrite) and a clearly-scoped v2 (agent) that only gets built once v1 has proven itself with real, non-founder users. Where this reverses an earlier "full scope in v1" decision, that reversal is deliberate and the reasoning is stated inline, not hidden.*

---

## 0. What Changed, and Why

The prior version of this PRD bundled three products' worth of risk into one v1: a proven dictation engine, an unproven rewrite layer, and an unvalidated, five-handler agent layer with real security exposure (most notably, unaddressed prompt-injection risk via captured screen content). The red team audit's core finding: the product's actual differentiated value — an agent safely acting on your behalf — was gated behind two paywalls that most trial users would never reach, while the riskiest and least-validated engineering (Terminal Handler safety, OAuth app review, five separate integrations) sat on the critical path before a single outside user had touched the product.

**The fix:** decouple the agent layer from launch entirely.

- **v1 ships as Free (dictation) + Pro (rewrite) — a real, sellable product on its own**, matching the value of Wispr Flow's core loop with a trust story it can't match, on a timeline two people can actually hit.
- **The agent layer becomes v2**, greenlit only after v1 has real usage and revenue data. When it ships, it ships smaller than originally scoped: Email + Calendar only, Terminal Handler behind an explicit developer-mode gate, File Organization Handler cut, Spreadsheet Handler still deferred.
- Everything agent-related in this document from Section 8 onward is now **forward-looking design intent for v2**, not a v1 commitment — kept here, not deleted, because the trust and safety requirements it establishes (confirmation before irreversible actions, no background screen capture, raw-parameter confirmations) need to be decided now even though they won't be built for months.

## 1. What Is It, In One Line

A free, local-first, open-source-forked voice dictation core — hold a key, speak in any of ~99 languages, get accurate text at your cursor in any app — paired with a paid AI layer that rewrites what you said into clean, polished text. That's the whole v1 product: it matches Wispr Flow's core loop, with a trust story built into the architecture instead of just claimed in marketing copy. A voice-driven agent that sees your screen and acts on your behalf — the HeyClicky-equivalent capability — is the deliberate, sequenced v2, not a v1 promise.

## 2. What Problem It Solves

**v1 problem:** Wispr Flow dictates and polishes text well, but requires an internet connection, processes centrally, and has a documented concern about reading keystrokes. There's no dictation tool that's genuinely local-first, open-source-auditable at its core, and still gets AI-polished output. That's the whole v1 gap, and it's real and sufficient on its own — it doesn't need the agent story to justify shipping.

**v2 problem (unchanged from before, just sequenced later):** HeyClicky goes further than dictation — voice plus screen awareness plus an agent that executes tasks across your apps — but it's fully cloud-mediated, closed-source, with no privacy story, and a materially higher price ($100/month at its top tier). Once v1 has proven the trust story and the core loop with real users, extending it into a safely-scoped agent layer is the differentiated move nobody else in this category is making.

**Cost of not solving it (v1 framing):** users who want private, local dictation with real AI polish have no option that isn't a compromise — either cloud-dependent Wispr Flow, or a pure open-source tool like open-wispr with no rewrite layer at all.

## 3. Who It's For

**Primary user (v1):** people who already dictate regularly and want the AI to clean it up — writers, professionals drafting email and docs, anyone who dictates faster than they type — while trusting that the tool isn't quietly reading everything they type or sending more than necessary off their machine.

**Also served, and previously unstated:** the accessibility market — people who dictate out of necessity (RSI, motor impairment, vision limitations) rather than preference. The red team audit flagged this as a real, underserved segment the prior draft never named. Reliable, local-first dictation is direct value here, independent of the rewrite or agent story, and it's worth naming explicitly rather than assuming it falls out of "professionals who dictate."

**Also served:** the existing Wispr Flow user base directly — proof of real, paying demand for exactly this core loop.

**Who it's not for (v1):** anyone whose primary interest is the agent/action-taking capability. Be direct about this rather than implying it's coming soon on a fixed date — v2 is real, but it's gated on v1 evidence, not a certainty on a calendar.

## 4. Goals

1. **Match Wispr Flow's dictation-plus-rewrite quality**, at a comparable or better price, with a trust story it structurally can't match (open-source local core, explicit no-keystroke-logging commitment, disclosed data flow for the one step that does leave the device).
2. **Get a real, non-founder paying user within 30 days of Phase 2 completing.** This is now an explicit goal, not an implicit hope — every later decision (including whether to build the agent layer at all) depends on this happening and being honestly evaluated.
3. **Generate real revenue from a two-tier structure** (Free dictation, Pro rewrite) that's simple to explain in one sentence — a deliberately smaller pitch than the three-tier, three-capability version, because a first-time user should understand the whole product in five seconds.
4. **Ship a working dictation core fast**, using the open-wispr fork, so v1 launches in weeks, not months.
5. **Establish, without yet building, the safety requirements the agent layer will need** — mandatory confirmation before irreversible actions, no background screen capture, raw (not paraphrased) parameters shown before confirming — so v2 starts from settled trust and security decisions instead of relitigating them under launch pressure.

## 5. Non-Goals

1. **The agent layer does not ship in v1.** This directly reverses the prior "full HeyClicky-matching scope in v1" decision. The reason: the agent layer was both the riskiest engineering (Terminal Handler safety, OAuth app review across two providers, five separate integrations) and the piece with zero outside validation, sitting on the critical path before v1 could even generate revenue. Reopened deliberately by the red team audit; this is the correction.
2. **No agent action, when v2 ships, executes without explicit confirmation for anything irreversible.** Unchanged from before — this was already correct and stays a hard line.
3. **No Windows support in v1 or v2's first release.** open-wispr is macOS-only; unchanged reasoning.
4. **No cloud storage of dictation history by default.** Local by default; unchanged.
5. **Not matching either competitor's full feature roster.** v1 matches Wispr Flow's core loop and wins on trust; it doesn't chase every feature either competitor ships.
6. **Not committing to a fixed v2 launch date in this document.** v2 is gated on v1 evidence (see Section 13 — Path to v2), not a calendar promise made before that evidence exists.

## 6. Competitive Landscape

- **Wispr Flow** — $15/month, dictation + AI rewrite, 100+ languages, real paying user base. This is now the **direct v1 competitor** — same core loop, we compete on trust architecture and price. Weaknesses: cloud-dependent, documented keystroke-reading concern, no action-taking capability at all.
- **HeyClicky** — Mac-native, YC-backed, voice + screen awareness + agent task execution. Free / Pro $20/mo / Max $100/mo. This is the **v2 competitor**, not a v1 concern — we're not racing them on agent capability until v1 has proven itself. Their capital and head start on agent execution is real and worth tracking, but it doesn't change the sequencing decision above.
- **open-wispr** — MIT licensed, fully local dictation engine (whisper.cpp), ~99 languages, zero network requests, no rewrite layer. The trust-verified foundation for the dictation core.
- **The v1 gap Murmur fills:** the only dictation-plus-rewrite product that is local-first and auditable at its core. **No durable moat yet** — open-wispr is MIT-licensed and forkable by anyone; the honest long-term differentiator is accumulated per-user value (rewrite presets, eventually Action Log history once v2 ships), which doesn't exist on day one and has to be built deliberately.

## 7. How We're Building It (Approach) — v1

**Two layers, each priced against what it actually costs:**

- **Free, local, forever — dictation.** Fork open-wispr's existing engine as-is: push-to-talk, cursor-position text injection, ~99 languages, zero network calls.
- **Paid — AI rewrite.** The raw local transcript is sent (text only, never audio) to a metered API call that cleans up grammar, punctuation, and filler words.

**Mechanically:** native macOS app, built on the open-wispr codebase. MIT license terms from open-wispr are retained and complied with.

**Trust commitment, stated as a requirement:** Murmur never reads keystrokes. What leaves the device for the rewrite step (text only, never audio) is disclosed plainly, before the fact.

**What's deliberately not being built yet:** screen capture, any third-party OAuth integration, any action execution. None of that exists in the v1 codebase — this isn't a feature-flagged agent layer waiting dormant, it's simply not built until v2 is greenlit. That's a smaller attack surface, a smaller permission ask, and a much shorter path to a real launch.

## 8. The v2 Agent Layer — Design Intent, Not a v1 Commitment

*Kept here deliberately: the trust and safety shape of the agent layer needs to be decided now, while there's no launch pressure, not improvised later. Building against this section is out of scope until the Path to v2 gate (Section 13) is met.*

**Scope, revised down from the original five-handler plan:**

- **Email Handler** and **Calendar Handler** — the two lowest-risk, cleanest-API action types. This is the entire v2 action set at first release.
- **Terminal Handler** — **removed from the mainstream product.** The red team audit was direct about this: the confirmation UI assumes a user who can read and judge a shell command, and that user is a developer — not the broadened, partly non-technical audience this product serves. If built at all, it lives behind an explicit, separate "developer mode" toggle that a mainstream user never sees or is prompted to enable.
- **File Organization Handler** — **cut from the plan entirely for now**, not just deferred to a later phase within v2. Lowest differentiated value of the original five actions; revisit only if Email + Calendar prove the agent concept has real demand.
- **Spreadsheet Handler** — still deferred, as before; cloud-hosted sheets only if it's ever built, local-file automation (Numbers, offline Excel) explicitly out of scope.

**Non-negotiable safety requirements for whenever this ships** (see the TRD for the technical mechanism behind each):
- Screen capture only on explicit invocation, never continuous or background — unchanged from the original commitment.
- Mandatory confirmation before any irreversible action.
- **Confirmation dialogs show the raw, resolved action parameters — the actual email address, the actual command text — never an AI-paraphrased summary.** This is new, and it exists specifically because captured screen content can contain hidden or manipulative text (a prompt-injection attack via a phishing email or malicious webpage on screen). A paraphrased confirmation can be manipulated to look safe; the raw parameters can't lie about what will actually happen.
- A visible, reviewable local Action Log.
- A plain-language explanation of *why* each permission is being requested, shown before the OS prompt — a direct answer to the audit's finding that four to six system permission dialogs is a lot to ask of a product whose whole pitch is "we take less than we need."
- A visible **dry-run mode** for onboarding: before a user's first real confirmation, they watch the agent simulate two or three real tasks so they understand what confirmation actually gates, lowering activation friction for the highest-trust-cost tier.

**Pricing intent for v2 (unresearched, explicitly a placeholder):** an agent tier priced meaningfully below HeyClicky's $100/month Max — but test a mid-tier (Email + Calendar only) against a larger bundle before assuming a big Pro-to-Max price jump converts best; the original two-step ladder was never validated.

## 9. Platform & Distribution

**v1: macOS only**, Sonoma 14.2+, Apple Silicon — matches open-wispr's base.

**Distribution cost:** Apple Developer Program notarization — **$99/year**, non-optional given how central trust is to the pitch.

**v2, when built:** will additionally require macOS Accessibility and Screen Recording permissions, requested progressively and only at first agent invocation — not at install.

**App Store risk, flagged and previously missing from this document entirely:** apps built around broad Accessibility-API-driven automation are frequently rejected from the Mac App Store outright. If Mac App Store distribution ever matters strategically, the v2 agent architecture may permanently exclude that channel. Worth deciding with eyes open before v2 engineering starts, not discovering after.

**v3 (future): Windows** — deferred; add an estimated $200+/year Windows code-signing cost when that phase starts.

## 10. User Stories

**Dictation core (v1):**
- As a privacy-conscious professional, I want my dictation to stay entirely on my device by default, so I can dictate sensitive material without worrying where it goes.
- As a non-native English speaker, I want to dictate in my own language and get accurate, well-formatted text.
- As a writer, I want my raw dictation cleaned up into readable prose automatically.
- As a person who dictates out of physical necessity rather than preference, I want a dictation tool that's reliable and doesn't depend on a network connection, so I'm not blocked by connectivity issues for something I depend on daily.
- *(Edge case)* As a user without an internet connection, I want dictation to keep working even though rewrite requires connectivity.

**Agent layer (v2 — captured for design continuity, not a v1 deliverable):**
- As a user, I want to speak a task aloud and have it actually get done, so I don't have to switch apps and do it by hand.
- As a user, I want to see and confirm exactly what the agent is about to do — in its literal, unparaphrased form — before anything irreversible happens, so I stay in control even if something on my screen was trying to manipulate what the agent thinks I asked for.
- As a security-conscious user, I want screen capture to happen only when I've actively invoked the agent, never silently in the background.
- As a non-technical user, I want a plain-language explanation of why each permission is being requested, so four or five system dialogs don't just feel like an alarming wall of "Allow access to..." prompts.
- *(Edge case)* As a user, I want a clear, reviewable log of every action the agent has taken on my behalf.

## 11. Requirements

**Must-Have (P0) — v1 only:**
- Fork and ship open-wispr's local dictation engine (push-to-talk, cursor injection, ~99 languages, zero network requests).
- Pro rewrite pipeline: transcribed text only sent to a metered API for cleanup, clearly disclosed.
- Explicit, testable trust commitments: no keystroke logging, ever.
- Stripe (or equivalent) billing across Free/Pro.
- Apple Developer ID notarization.
- Open-source dictation core (MIT license retained and complied with).
- A shareable before/after (raw transcript vs. rewritten) moment — the audit's finding that **no growth loop exists anywhere in the prior plan** gets fixed here: this is close to free to build and gives the product its first organic distribution mechanism.
- A defined referral mechanism (extended trial for both sides is the working assumption) — same gap, same fix.

**Nice-to-Have (P1) — v1:**
- Custom rewrite tone/style presets.
- Usage dashboard covering dictation and rewrite activity.
- SEO-targeted landing content against "Wispr Flow alternative" — both direct competitors are small enough that this is a winnable, low-competition play.

**Future Considerations (P2) — v2 and beyond, gated on Section 13:**
- Agent layer: Email + Calendar Handlers, developer-mode-gated Terminal Handler, dry-run onboarding, raw-parameter confirmations, local Action Log.
- Windows support.
- Custom vocabulary/terminology training.
- Optional, explicitly opt-in encrypted history/sync across devices.
- Bring-your-own-API-key mode for the most privacy-paranoid segment — a real technical differentiator nobody else in this category offers, and it caps cost exposure for that segment.
- Exportable Action Log as a B2B/compliance upsell, once the Action Log itself exists — a genuinely distinct buyer from the individual consumer ladder, unexplored by either competitor.

## 12. Success Metrics

**North Star:** weekly active dictation volume (successful dictations completed, not installs) — reflects real habitual use, and doesn't require the agent layer to mean anything.

**If only 5 events:** `dictation_completed`, `rewrite_invoked`, `subscription_tier_changed`, `before_after_shared`, `referral_sent`. (`agent_action_confirmed` / `agent_action_result` get added back once v2 is real — deliberately excluded from the v1 metrics set so the dashboard doesn't have empty columns for a feature that doesn't exist yet.)

**Leading (days–weeks):** downloads in the first 30 days; % of installs completing a first successful dictation; % of free users trying Pro rewrite; share rate on before/after snippets; referral sends per active user.

**Lagging (weeks–months):** 30/60-day retained active usage; Pro subscription retention month-over-month; qualitative, unprompted feedback on whether people want more than dictation+rewrite (this is the actual signal that greenlights v2 — see Section 13).

**A note the prior version missed:** dictation is naturally habitual (multiple times a day); any future agent usage would follow a much lower-frequency curve (plausibly weekly). These are two different retention curves. If v2 ever ships, its metrics need to be tracked and judged separately from dictation's — blending them into one retention number would hide whether either product is actually healthy.

## 13. Path to v2 — What Has to Be True Before the Agent Layer Gets Built

This section didn't exist before, and it's the direct mechanism for the decision made in Section 0. The agent layer is not cancelled — it's gated. It gets greenlit when:

1. v1 has real, non-founder paying users (target: the first real signal within 30 days of Phase 2 shipping, per Goal 2).
2. There's a measurable free-to-Pro conversion rate to model unit economics against, since the agent tier's cost structure (vision API calls, materially more expensive than rewrite's text-only calls) needs real usage data to price correctly — the prior $40–60/month Max estimate was set without this and was explicitly unresearched.
3. There's unprompted user signal — people asking for more than dictation+rewrite, not just a hypothesis that they would want it.
4. A honest answer exists to whether "just the two of us" can safely build the agent layer's safety-critical pieces (Terminal Handler sandboxing, OAuth app review lead time, adversarial security testing) without compressing the timeline to fit an external deadline.

Until all four are true, this document's v2 sections are architecture and safety intent, not a backlog.

## 14. Open Questions

- **[Product]** Are the $10–15 Pro price anchor and the (now-deferred) agent-tier pricing right? Still explicitly unresearched.
- **[Product]** Exact referral mechanism design — extended trial is the working assumption, not yet validated.
- **[Legal]** MIT license compliance details for the open-wispr fork.
- **[Product]** Final product name — "Murmur" is a placeholder pending a trademark check. Twice deferred now; worth resolving before more brand-specific work compounds the cost of eventually redoing it.
- **[Legal, new]** Liability/ToS framing for the eventual agent layer — what happens when it sends a wrong email or runs a damaging command — needs to exist before v2 ships, not after an incident.
- **[Legal, new]** Cross-jurisdiction data-protection exposure from screen capture that incidentally captures a third party's data (a colleague's email visible in an inbox) — unconsidered until this audit, needs real legal input before v2, not v1.

## 15. Timeline Considerations

v1 (dictation + rewrite) is a substantially smaller, faster build than the combined version of this PRD was — weeks on top of a working fork, not months of new systems engineering. That's the point: a real, working, revenue-generating product should exist before the harder agent-layer engineering starts, not after months of building toward an unvalidated three-tier vision. The TRD that follows this PRD scopes its build sequence to match.
