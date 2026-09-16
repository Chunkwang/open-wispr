# Brand Color System

*Name-agnostic — applies regardless of what we land on once "Murmur" is replaced. Revised after the Product Red Team Audit's scope decision: v1 ships as dictation + rewrite only, agent layer sequenced to v2. The core palette and rationale below are unchanged — the audit didn't find anything wrong with the color direction itself. What changed is when and how much the semantic danger/warning system actually gets used, and the "what's still needed" list at the end.*

---

## 1. Direction: Deep Forest Green

Rationale, stated plainly: both direct competitors (Wispr Flow, HeyClicky) sit in the same visual lane — black, white, gray, with blue undertones. That's the generic "trustworthy tech" palette every SaaS tool defaults to. We have a sharper, more provable trust story than either of them (open-source core, zero background data collection, no keystroke logging, local-first by architecture, not by claim) — a generic blue palette would visually say "we're the same as everyone else" right as we're trying to say the opposite. Deep green reads as private, grounded, "off-grid," secure — without leaning on the one color (blue) that's become wallpaper in this category. This holds just as true for a smaller v1 — the trust story is fully present in dictation + rewrite alone, it doesn't need the agent layer to justify the visual direction.

## 2. Core Palette

| Role | Color | Hex | Use |
|---|---|---|---|
| **Primary (brand anchor)** | Deep forest green | `#1B4332` | Wordmark, primary chrome, key brand moments |
| **Interactive accent** | Emerald | `#2D8659` | Buttons, links, active states — needs to read as clickable on both light and dark backgrounds, so it's meaningfully brighter than the anchor color |
| **Dark mode background** | Off-black, green-tinted | `#0D1210` | Not pure black — a near-black with a faint green undertone ties the neutral into the identity instead of looking like a default dark-mode gray |
| **Light mode background** | Off-white, green-tinted | `#F7F9F7` | Same logic in reverse — avoids looking like default Tailwind/Bootstrap gray-50 |
| **Body text (dark mode)** | Soft white | `#E8EDE9` | Full white (`#FFFFFF`) on near-black is harsher than needed for long reading — softened slightly |
| **Body text (light mode)** | Near-black, green-tinted | `#14201B` | Mirrors the dark-mode logic |
| **Muted / secondary text** | Sage gray | `#8A9A92` | Timestamps, captions, disabled states — works in both modes |

## 3. Semantic Colors — the part that actually matters most

This is the correction I want to be direct about, because it's not a style preference, it's a safety issue tied directly to the TRD's Confirmation Layer requirement — and it's worth being equally direct about the fact that **in v1, this semantic system is mostly dormant.** There's no agent layer yet, so there's no irreversible-action confirmation to protect. Specify it now anyway, for two reasons: it costs nothing to lock in early, and v1 still has a handful of legitimate uses for "success" and "error" states (a completed rewrite, a failed API call) that should already be using the right colors rather than improvising.

**Do not use brand green for the "confirm this irreversible action" button, whenever that button exists.** If the Confirm button on "send this email" or "run this terminal command" is styled in the same friendly brand green as every other button in the app, it starts to look like just another normal action — and the entire point of the Confirmation Layer is that irreversible actions should feel *different* from routine ones, not visually blend in. A user who's clicked "confirm" in brand-green a hundred times for harmless things will click it just as fast the time it matters.

So: irreversible-action confirmations get their own distinct color, deliberately outside the brand palette, using colors people already read as "pay attention" from years of software conditioning:

| Role | Color | Hex | Use in v1 | Use in v2 |
|---|---|---|---|---|
| **Danger / irreversible action** | Red | `#C0392B` | Not used yet — no irreversible actions exist in v1 | Terminal command execution, sending an email, deleting/overwriting — the confirm button itself, not just an icon |
| **Warning / needs review** | Amber | `#B8860B` | Not used yet | Lower-stakes-but-not-nothing actions — e.g., calendar invite going to other people |
| **Success / completed** | Muted teal-green | `#3D8168` | A completed rewrite, a successful billing action | Action completed confirmation — deliberately distinct from both the interactive accent and the danger color, so "done" doesn't look like "confirm" |
| **Error / failed action** | Red (same as danger) | `#C0392B` | Rewrite API call failed, billing/payment error | API failure, action couldn't complete |

This gives the product a real, consistent visual grammar from day one — green means "the brand, and routine navigation," amber/red mean "stop and read this before you click" — even though the highest-stakes use of that grammar (the agent layer's confirmation dialogs) won't exist until v2. Locking the system now means v2 inherits a settled, already-tested visual language instead of improvising one under launch pressure, which is exactly the kind of thing the red team audit flagged as worth deciding early.

## 4. Accessibility

Every text/background pairing above needs to be run through an actual contrast checker (WebAIM's or similar) before this ships — I'm giving you a reasoned direction, not certified WCAG numbers. Flag as a to-do, not assumed done: the deep forest green (`#1B4332`) as a background with white text should pass AA comfortably given how dark it is; the emerald accent (`#2D8659`) needs specific checking wherever it's used as button text-on-color, since mid-tone greens are exactly where contrast failures tend to hide. Worth doing before v1 ships, not deferred to v2 — v1's own success/error states already use this palette.

## 5. Light vs. Dark Mode Default

Recommend **dark mode as the default**, light mode as the alternative. Reasoning: both direct competitors already lean dark/near-monochrome, so this isn't differentiation on its own — but the actual target user (developers, privacy-conscious professionals, and, per the PRD's now-explicit accessibility audience, people who dictate out of necessity) skews toward dark-mode-by-default software, and it reinforces the "security tool" feel more than a bright, airy light theme would.

## 6. What's Still Needed (Not This Document)

- **Final product name** — still the actual blocker; colors and a wordmark can't truly lock until this resolves. Twice deferred now.
- **Typography and logo mark** — already in progress separately (see the visual identity reference); unaffected by the v1/v2 scope change, since both were already built name-agnostic and feature-agnostic.
- **Full contrast validation** — see Section 4, needed before v1 ships.
- **v2 semantic-color application design** — once the agent layer is actually greenlit (see the PRD's Path to v2), the danger/warning colors specified here need real confirmation-dialog UI work, not just the palette values already locked in this document.
