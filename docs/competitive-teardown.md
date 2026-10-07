# Competitive teardown: HeyClicky and Wispr Flow

*Desk research, 2026-09-25. No product was installed or used. Every claim carries a label:*
- **[Company]** stated on the company's own site or repo.
- **[Third party]** stated by a review, article or aggregator (may be wrong, dated, or biased; bias noted where known).
- **[Inference]** our reasoning from the facts.
- **[Unverified]** could not be confirmed. Do not repeat it publicly until checked.

The hands-on half of this teardown is `docs/heyclicky-teardown-checklist.md` (about an hour, done by the founder).

## 1. Corrections to things we said or wrote earlier

| What we said | What the sources show | Action |
|---|---|---|
| "HeyClicky is closed source" (PRD Section 6 and my earlier table) | The original client is **MIT-licensed and public** at github.com/farzaa/clicky, about 7.6k stars and 1.5k forks. Its README says current development is private and the repo is "the open-source version". [Company repo] | Correct the PRD before any marketing claim. Do not say HeyClicky is closed source; say "current development is private". |
| "HeyClicky has no privacy story" (PRD Section 2) | It has a trust page: screenshots are not stored after processing, no training on user data, no SOC 2 or ISO 27001 yet. [Company] | Compete on facts (below), not on "they have none". |
| "Wispr Flow is cloud-dependent" (PRD; I flagged it unverified on 2026-09-24) | Confirmed by its own data-controls page: "Transcription always occurs on the cloud." [Company] | Safe to say. |
| "HeyClicky does not support Intel" (implied by our own Apple-Silicon-only scope) | A third-party review says it supports both Apple Silicon and Intel. [Third party] | Not a claim we make; note for comparison pages. |

## 2. HeyClicky

**What it is.** A Mac menu-bar "AI buddy": hold a hotkey, ask about what is on screen, it answers (spoken) and can point at controls on screen; "agent" mode runs longer computer-use tasks; dictation. Company: Humansongs, Inc. [Company: about page]. Described as Y Combinator Spring 2026 by several third parties; the company pages we read do not say so. [Third party]

**Features.** Push-to-talk screen-aware help; on-screen pointing and drawing; Talk mode; Agent mode; system-wide dictation in 50+ languages; reads whole-document context; reusable "Skills"; automatic model routing. [Third party: The Rundown] Multi-step walkthroughs up to 15 steps (raised from 5). [Third party: HokAI]

**Pricing.** Free $0 (25 talk and 25 agent messages a month, limited dictation); Pro $20/month (unlimited talk and dictation, 150 agent messages); Max $100/month (1,000 agent messages); 20% off annually. [Company for the tiers; Third party for the annual discount] Agent allowance is "the real constraint". [Third party]

**Platform.** Mac only, macOS 14.2 or later; Windows waitlist with no date. [Company]

**Privacy and data flow.**
- "Everything is processed in the cloud where we forward the request to either anthropic or openai." [Company: trust page]
- Raw screenshots are never stored; the AI-generated screenshot analysis and your prompt are kept. No training on your data, by them or providers. No SOC 2 or ISO 27001 yet. Analytics via PostHog and Sentry (not screen data). [Company: trust page]
- The public open-source client shows the data flow: microphone audio streams to AssemblyAI (cloud transcription), transcript plus screenshot go to Claude, replies are spoken by ElevenLabs, all three proxied through a Cloudflare Worker. Permissions: microphone, Accessibility, Screen Recording. Screen capture uses ScreenCaptureKit. Cursor pointing works by the model emitting coordinate tags. [Company: repo README, as read 2026-09-25] The paid product may differ (third parties also list Deepgram and Cerebras). [Third party]
- Its changelog reportedly shows proactive background agents were turned off over privacy concerns, and past bugs (chats stalling, work lost across a relaunch). [Third party: search summary of the changelog; not opened directly]

**Weaknesses named by third parties.** Cloud dependency rules it out for sensitive screens; no compliance certification; very new company; powerful permissions are a risk if compromised; an "always approve" option removes safety checkpoints; modest agent caps on Pro; no public API. [Third party: HokAI, The Rundown] Platform risk: Apple Intelligence on-screen awareness could make the idea an OS feature. [Third party, speculation]

**Not stated anywhere we read.** How agent confirmations work in detail, accuracy and latency numbers, how it treats password fields. These go on the hands-on checklist.

## 3. Wispr Flow

**What it is.** System-wide voice dictation with AI clean-up ("Flow"), Mac, Windows, iOS. [Company]

**Pricing.** Free $0 (basic dictation); Pro $15/month or $12/month annual; Growth $23 / $18; Enterprise custom. [Company: pricing page]

**Privacy and data flow.**
- "Transcription always occurs on the cloud." Audio streams to their servers; processing is in memory; some model requests go to vetted third parties under zero-data-retention terms. [Company: data-controls and security pages, via search summary]
- "Dictation Cloud Storage" setting decides whether transcripts, audio and history are stored. Training on data is opt-in. If "Context Awareness" is on, "relevant text data from the active app window may be used". SOC 2 Type 2 and HIPAA shown; ISO 27001 per a third party. [Company; Third party]
- **Privacy incident:** in late 2025 users watching network traffic reported periodic screenshots of the active window being sent; the reporting user was reportedly banned, the CTO later apologised; the company then made training opt-in and added a Privacy Mode. The one article we read stresses that users cannot audit whether Privacy Mode works. [Third party: ModelPiper, which itself summarises a Medium post; treat details as unconfirmed]

**Reliability and quality (user and aggregator reports).**
- Over 75 outages logged since 2025-12-18 and about 20 in the 30 days to 2026-06-08 (StatusGator data, quoted by Voibe, which sells a competing on-device product, so read the framing with that bias in mind; the outage counts come from a third-party tracker and Wispr's own status page). [Third party]
- Ratings: about 4.8 on the iOS App Store (~10,000 ratings), 2.7 on Trustpilot, with a recurring "worked in the trial, degraded after paying" pattern. [Third party]
- Complaints: the clean-up "trying to rewrite what I say" instead of transcribing; about 800 MB RAM and 8% CPU at idle; freezes in some editors. [Third party: user reports]
- Latency claimed under 700 ms at p99; users report 1 to 2 s in practice. [Third party]

## 4. Side by side (only what we can source)

| | HeyClicky | Wispr Flow | Us today |
|---|---|---|---|
| Speech-to-text runs | Cloud (in the open client: AssemblyAI) | Cloud, "always" | **On the Mac** (whisper.cpp) |
| Works when their servers are down | No (cloud) | No | **Dictation yes**; rewrite falls back to your raw words |
| Screen data | Screenshot on hotkey to Anthropic/OpenAI; analysis and prompt retained | Text of active window if Context Awareness is on; past screenshot incident | Not built yet (Stage C); design keeps a per-data-type consent and retains nothing server-side |
| Open source | Original client MIT; current development private | No | **MIT core** (fork of open-wispr) |
| Compliance | None yet | SOC 2 Type 2, HIPAA | None (not a goal for v1) |
| Price | Free / $20 / $100 | Free / $15 (or $12) / $23 | Not set; PRD placeholder $10 to $15 |
| Agent (does things) | Yes, metered | No | Planned (Email + Calendar), not built |
| Screen pointing/drawing | Yes | No | Not planned |
| Spoken replies | Yes (ElevenLabs) | No | Not planned |

## 5. What this means for us [Inference]

1. **The shared weakness is the cloud.** Both competitors send audio or screens to servers; Wispr has documented outages and a privacy incident; HeyClicky retains analyses. A product whose dictation works with the network unplugged, that never loses your words, and that can prove what it sends is a real position, not a slogan.
2. **The "screen buddy" idea has no feature moat.** A working MIT-licensed reference (Swift menu-bar app plus Cloudflare Worker, the same architecture as ours) has thousands of stars. Anyone can build the loop. Our advantage has to be trust, reliability and price, plus execution speed.
3. **We can learn from the MIT reference legally** (our project is MIT too; keep its notice and attribution if any code is reused), for example ScreenCaptureKit capture and the pointing-tag idea. Have the tech-lead and macos-engineer read it before Stage C tasks C4 and C8, and decide what, if anything, to reuse.
4. **Do not fight on breadth.** They will out-ship us on model routing, spoken replies, skills and integrations. We win where a large cloud team is structurally weaker: local-first, auditable, calm.
5. **Trust cuts both ways.** Wispr Flow's incident shows one unverifiable privacy claim can cost a company its reputation. Every claim we publish must be traced to code (`TRUST.md`, Task 5.2/5.3) and, where possible, enforced by a test or CI check, as we already do for the consent gate.
6. **Platform risk:** Apple may ship on-screen awareness in the OS. Our answer is to stay small, private and fast, and not to depend on any single feature.

## 6. Open questions the hands-on hour should answer

See the checklist. The big ones: how good is the pointing really, how reliable are agents, what does each permission prompt say, what is the real latency, and how does it behave with sensitive screens.

## 7. Sources (all accessed 2026-09-25)

- HeyClicky home, about, trust: https://www.heyclicky.com/ , https://www.heyclicky.com/about , https://www.heyclicky.com/trust
- HeyClicky open-source client (MIT): https://github.com/farzaa/clicky
- HeyClicky review (features, pricing, pros and cons): https://www.therundown.ai/tools/clicky
- HeyClicky review (open source, safety, platform): https://hokai.io/hub/tools/heyclicky
- HeyClicky changelog (read only as a search summary): https://www.heyclicky.com/changelog
- Wispr Flow pricing: https://wisprflow.ai/pricing
- Wispr Flow data controls: https://wisprflow.ai/data-controls ; security FAQ: https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq
- Wispr Flow privacy incident (article): https://modelpiper.com/blog/wispr-flow-privacy-incident
- Wispr Flow reliability log (author sells a competitor): https://www.getvoibe.com/resources/is-wispr-flow-reliable/
- Other products that appeared in searches and were not researched: Highlight AI, Guidy, VoiceOS, Carly.
