# Brand Voice & Tone Guide

*Name-agnostic — every sample below uses generic references ("the app," "we") so this survives the eventual rename intact. Revised after the Product Red Team Audit and the resulting scope decision: v1 ships as dictation + rewrite only, with the agent layer sequenced to v2. The personality and voice/tone framework below didn't need to change — the audit didn't flag anything wrong with it. What changed is the sample copy: v1 samples now reflect a two-permission, two-tier product, and the agent-layer samples are kept but clearly marked as v2, written against the stricter safety requirements the audit produced (raw-parameter confirmations, a developer-mode gate, plain-language permission explainers).*

---

## 1. Personality

Five words, and what each one rules out:

- **Direct** — says what's happening in plain terms. Rules out marketing softness ("enhanced privacy experience" instead of "we don't read your keystrokes").
- **Calm** — never manufactures urgency to drive action. Rules out artificial scarcity, exclamation points, "act now" energy — especially wrong for a security-relevant product, where urgency is exactly what makes people click through things they shouldn't.
- **Competent** — sounds like it was built by people who know what they're doing, without needing to say so. Rules out over-explaining basic concepts to a technical audience, and rules out jargon that alienates the non-technical half of the audience.
- **Honest about limits** — says what it doesn't do or can't guarantee, not just what it can. Rules out overselling AI reliability ("perfect every time"), and — new emphasis post-audit — rules out implying the agent layer exists before it does. v1 marketing and in-app copy say what the product does today, not what's planned.
- **Quietly confident** — sure of itself without performing confidence. Rules out hype language ("revolutionary," "game-changing," "supercharged").

## 2. Voice vs. Tone

**Voice never changes** — it's the five traits above, present in every piece of copy regardless of context.

**Tone shifts with the moment:**

| Context | Tone |
|---|---|
| Routine dictation / everyday UI | Neutral, brief, almost invisible — the tool should get out of the way |
| Onboarding / first-run | Warmer, more explanatory — this is the one moment a little more hand-holding is earned |
| Permission requests (mic, accessibility — and, in v2, screen recording/OAuth) | Maximally plain — no persuasion, just a factual statement of what's being asked and why |
| Confirmation dialogs (v2 — irreversible agent actions) | Serious, unambiguous, zero personality — this is not the moment for brand voice to be charming |
| Errors | Calm, specific, no apology theater ("Oops!") — say what broke and what to do |
| Marketing / landing page | The most personality-forward the voice ever gets, still short of hype — and, post-audit, scoped honestly to what v1 actually does |

## 3. Do / Don't

**Do:**
- Say exactly what data moves and when. "Only the text is sent for rewriting" beats "your privacy is protected."
- Use the second person ("you," "your") — this is a tool acting on someone's behalf, not a faceless system.
- Keep confirmation and permission copy under two sentences. If it needs more than that to be clear, the design is the problem, not the copy.
- Name the actual action in a button label. "Run command" beats "Continue."
- **New:** describe the product as what it is today. v1 is a dictation-and-rewrite tool. Marketing copy doesn't tease agent capability that isn't shipped, doesn't have a committed date, and is explicitly gated on v1 usage data per the PRD.

**Don't:**
- Don't use exclamation points outside of genuine, rare delight (a successful first dictation on onboarding, maybe — never in a confirmation or error).
- Don't say "smart," "seamless," "powerful," or "magic" — these describe nothing and every competitor uses them.
- Don't apologize for errors ("Oops, something went wrong!") — state what happened and what to do next.
- Don't use "simply" or "just" before an instruction ("simply click confirm") — if it were simple, it wouldn't need the word.
- Don't let marketing tone leak into the confirmation layer. This is the one rule worth enforcing hardest, because it's a safety issue: if "Run command" sounds like the same voice as a landing page headline, the moment stops feeling different from routine use — and it needs to.
- **New:** don't paraphrase what a confirmation dialog is about to do. Say the literal thing — the actual recipient, the actual command — never a friendly summary of it. (See Section 4's v2 confirmation samples, and the TRD's prompt-injection rationale for why this is now a hard rule, not a style preference.)

## 4. Sample Copy by Moment

### v1 (dictation + rewrite) — what ships first

**Onboarding, first screen:**
> Hold the key, say what you want written. It stays on this Mac unless you tell it otherwise.

**Microphone permission request (shown before the OS prompt):**
> We need microphone access to hear what you dictate. Audio is processed on this device and never saved or sent anywhere for the free tier.

**Accessibility permission request:**
> Accessibility access lets the app place your dictated text wherever your cursor is. It doesn't let the app read anything you haven't dictated.

**Error — rewrite API call failed:**
> Couldn't reach the rewrite service. Your raw transcript was inserted instead — nothing was lost.

**Upgrade prompt (Free → Pro):**
> Rewrite cleans up filler words and punctuation automatically. It costs us a small amount per use, which is why it's the one thing we charge for — everything else stays free.

**Empty state — usage dashboard, no rewrite activity yet:**
> Nothing rewritten yet. Every cleanup will show up here, before and after, so you can see exactly what changed.

**Share prompt (before/after snippet — the v1 growth loop the audit flagged as missing):**
> Worth sharing? This shows the raw transcript next to the rewritten version — nothing else leaves your device to generate it.

**Referral prompt:**
> Know someone who dictates a lot? Send them an invite — you both get an extended trial of rewrite.

**Marketing headline candidates (for later, once the name is locked — scoped honestly to v1):**
> "Speak once. It stays yours."
> "Dictation that doesn't leave the room."
> "The AI polish for your dictation, without the cloud dependency."

### v2 (agent layer) — design intent, kept for continuity, not yet shippable

*These samples describe copy for a layer that doesn't exist in the product yet. Kept here so the voice is already decided if and when the PRD's Path-to-v2 gate is met — not a signal that this is coming soon.*

**Screen recording permission request (agent layer, first invocation):**
> The agent needs to see your screen to understand what you're asking it to do. It only captures a screenshot when you invoke it — never continuously, never in the background.

**Plain-language permission explainer (new — directly answers the audit's "four to six permission dialogs" finding):**
> This is the only new thing the agent needs beyond dictation: a one-time look at your screen when you ask it to do something, and access to send on your behalf for the specific app you're connecting. Nothing runs in the background.

**Confirmation dialog (irreversible action) — matches the visual identity reference, and now states the literal parameters, not a summary:**
> Confirm before running
> This will run, exactly as shown:
> `rm -rf ./dist && npm run build && npm run deploy`
> [Cancel] [Run command]

**Confirmation dialog (sending an email) — same rule, literal recipient and subject, not a paraphrase:**
> Confirm before sending
> To: sam@example.com
> Subject: Thursday meeting — Can we push to 3pm?
> [Cancel] [Send email]

**Developer mode toggle (new — the audit's recommendation to gate the Terminal Handler out of the mainstream product):**
> Developer mode adds one capability: running terminal commands you dictate, always shown in full and always confirmed before they run. Off by default — most people won't need it.

**Dry-run onboarding (new — the audit's recommendation to let people watch before trusting the agent with something real):**
> Before the agent touches anything real, watch it work through two example tasks. Nothing happens outside this preview.

**Error — agent action failed mid-execution:**
> The command stopped partway through. Here's exactly what ran before it failed: [log]. Nothing further was executed.

**Empty state — Action Log, no activity yet:**
> Nothing logged yet. Every action the agent takes on your behalf will show up here, in order, whether it succeeded or not.

## 5. One Rule That Overrides Everything Else Here

If a piece of copy is about to execute an irreversible action, drop every stylistic instinct above except plainness and precision. The brand can be quietly confident everywhere else. In that one moment, it should sound almost clinical — because that's exactly the signal a careful user needs to slow down and actually read it. And, per the audit: it should say the literal thing that's about to happen, never a friendlier paraphrase of it.
