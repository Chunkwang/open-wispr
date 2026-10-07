# Sign-in window: design spec

Day 4 of `docs/auth-design.md`. One window, two steps (email, then code), plus a signed-in confirmation and one failure screen. Strings are in `docs/design/sign-in-copy.md` and are referred to here by key. Sizes are in points. This file is written to be built from without questions: where a decision could have gone two ways, one way is chosen and the reason given. Anything that could not be verified without running the app is collected in the last section.

Constants used below (put them in one place, e.g. `SignInTimings`):

| Name | Value | Source |
|---|---|---|
| `codeLifetimeSeconds` | 600 | auth-design section 6 (server OTP expiry is set to 600 on Day 16) |
| `resendCooldownDefault` | 60 | mock `MOCK_OTP_RESEND_SECONDS`; used when a 429 has no `Retry-After` |
| `maxWrongTries` | 5 | auth-design section 6 |
| `lockoutSeconds` | 30 | auth-design section 6 |
| `minCodeDigits` / `maxCodeDigits` | 6 / 10 | auth-design section 6 |
| `maxEmailLength` | 254 | auth-design section 6 |
| `requestTimeout` | 10 s | `AuthService` (`RewritePipeline.makeSession(.ephemeral, timeout: 10)`) |

---

## 1. Window

| Property | Value |
|---|---|
| Class | `SignInWindowController` (singleton, `static let shared`), hosting a SwiftUI view through `NSHostingController`, like `OnboardingWindowController`. |
| Content size | 420 x 372, fixed for every state (no resize animation between steps). Not resizable, not miniaturizable. |
| Style mask | `[.titled, .closable]` |
| Title | `windowTitle` ("Sign in"). |
| Level | `.normal`. See open question 1 (floating). |
| Collection behaviour | `[.moveToActiveSpace, .fullScreenAuxiliary]`, so the window appears on the Space the user is on, including over a full-screen app. |
| `isReleasedWhenClosed` | `false`, and the controller sets its `window` to nil in `windowWillClose`, so the next `show()` builds a fresh window and a fresh model (email step, empty fields). |
| Appearance | Never set `window.appearance`. Follow the system. Dark is the design default (the palette doc), light is fully supported; section 3 has both. |
| Background | `BrandColor.darkBackground` / `lightBackground` filling the whole content view, as `OnboardingView` does. |
| Position | `center()` on first show. |

### 1.1 Menu bar (LSUIElement) behaviour

The app runs `.accessory` (`main.swift`) and has no Dock icon and no main menu. Four consequences, each a requirement:

1. **Activate and become key.** `show()` runs on the main thread and does, in this order: install the main menu if not yet installed (1.2); create or reuse the window; `NSApp.activate(ignoringOtherApps: true)` (as `OnboardingWindowController` does; use `NSApp.activate()` if the deployment target allows); `window.makeKeyAndOrderFront(nil)`; then on the next run-loop turn (`DispatchQueue.main.async`) make the correct field first responder (email field on the email step). The async hop is required: setting focus in the same turn as ordering the window front loses it.
2. **One instance.** `show()` while a window exists does not create a second one and does not reset state: it activates the app and brings the existing window to the front. This matters because the user leaves the window to read the email (item 3 below): the menu item "Sign in…" is the way back, since an accessory app is not in Cmd-Tab and has no Dock icon. The menu item stays enabled while the window is open for exactly this reason.
3. **Do not close on losing focus.** The window stays open behind other apps while the user reads the code in Mail. Never use `hidesOnDeactivate`.
4. **Never change the activation policy.** Do not switch to `.regular` (it would show a Dock icon).

### 1.2 Main menu for text editing (required)

The app has no main menu, and an accessory app without one gets no Command-V, Command-C, Command-A or Command-Z in text fields. Pasting the code is the primary path, so the window cannot ship without this. Before the first `show()`, install once:

- item 0: an empty app menu item (a main menu must have a first item);
- **Edit** submenu: Undo `undo:` (Cmd-Z), Redo `redo:` (Shift-Cmd-Z), separator, Cut `cut:` (Cmd-X), Copy `copy:` (Cmd-C), Paste `paste:` (Cmd-V), Select All `selectAll:` (Cmd-A). Target nil (first responder);
- **Window** submenu: Close `performClose:` (Cmd-W).

The menu bar does not show it because the app is `.accessory`; it only supplies the key equivalents. The Edit titles are never seen, but use standard English names so a future audit does not find odd ones.

### 1.3 Closing

Any of: the close button, Esc, Cmd-W, Done. All go through `windowWillClose`, which sends the model `closeRequested`. Closing is always allowed, including while a request is in flight, and never asks for confirmation (the worst loss is a code that was already sent, which costs a new code). In-flight results that arrive after closing are discarded (see the state machine's generation rule). Closing discards everything: the entered email, the digits, the counters, the timers. Nothing is written to `UserDefaults` or `config.json`.

Esc: implement in an `NSWindow` subclass (`SignInWindow`) by overriding `cancelOperation(_:)` to call `performClose(nil)`, so it works whichever control has focus, including the text field's field editor.

---

## 2. Layout

All steps share one grid so the primary button never moves. Horizontal padding 40, so controls are 340 wide. Vertical positions are measured from the top of the content view (below the title bar). Regions marked "reserved" keep their height when empty, so an error appearing never shifts anything.

| y | Height | Region | Style |
|---|---|---|---|
| 28 | 44 (reserved, 2 lines) | Heading | 17 pt regular, `text`, centred, top-aligned. Same style as the onboarding body text. |
| 78 | 32 (reserved, 2 lines) | Sub line | 13 pt regular, `mutedText`, centred, top-aligned. |
| 122 | 16 | Field label | 12 pt medium, `mutedText`, left-aligned, sits 6 above the field. |
| 144 | 44 | Field | Corner radius 8; fill `fieldFill`; 1 pt inside stroke `fieldStroke`; while focused a 2 pt stroke in `BrandColor.emerald` replaces it (same outer size, so nothing moves). Horizontal text inset 12. |
| 196 | 36 (reserved, 2 lines) | Status row | 13 pt regular, left-aligned, icon 14 pt at the left with 6 gap. See 5. |
| 248 | 36 | Primary button | Full width (340), corner radius 6 (as onboarding), 13 pt medium label. See 2.1. |
| 296 | 28 | Secondary row | See 2.2. |
| 330 | 16 | Caption | 12 pt regular, `mutedText`, centred. Code step only. |
| 372 | | Bottom edge | 26 below the caption |

### 2.1 Buttons

All buttons are custom-styled to the onboarding button (plain button style, fill, corner radius 6, 13 pt medium label) so they look like the rest of the app and every colour is one of the proven pairs in section 8. They still must be real controls (`Button`, or `NSButton`), never gesture-tapped views, so they are focusable, expose the button role, and respond to Space.

| State | Primary (emerald) button | Secondary (outlined) button |
|---|---|---|
| Normal | Fill `BrandColor.emerald`, label white. | Fill clear, 1 pt stroke `fieldStroke`, label `text`. |
| Pressed | Fill `buttonFillPressed` (emerald darkened 15 percent). | Fill `fieldStroke` at 15 percent opacity. |
| Disabled | Fill `disabledFill`, label `disabledLabel`, not focusable. | Stroke `fieldStroke` at 40 percent, label `mutedText`, not focusable. |
| Loading (busy) | Fill stays `BrandColor.emerald` (busy is not disabled: it must not look greyed out), a 14 pt indeterminate `ProgressView` in white left of the label, label replaced by the progress string. Clicks ignored. The VoiceOver label is the progress string. | Same, with a `text`-coloured spinner. |
| Keyboard focus | Outer focus ring 2 pt, `BrandColor.emerald` at full opacity, 2 pt outside the button (contrast 4.2 and 4.25 against the backgrounds, section 8). | Same. |

Emerald is used only as a button fill (white text on it), a 2 pt focus stroke, and never as the colour of text or a small glyph, on either background. Nothing on this window uses `forestGreen`, amber or the brand green for an error or a warning. Errors use `errorText`; there is no irreversible action on this window, so the danger button treatment is not needed here.

### 2.2 Secondary row

Two buttons of 164 x 28 with a 12 gap (left button x = 40, right button x = 216). If only one is shown it keeps its slot (left slot empty leaves the right one where it is; the email step's single button is 340 wide, centred).

---

## 3. Colour tokens

Existing tokens are in `BrandColor` (`OnboardingWindow.swift`). The window needs a few more; they are new adaptive tokens to add to `BrandColor` (or a `SignInPalette` next to it), because the palette doc leaves several roles undefined and some current values fail contrast. Every value below was computed (section 8). Pick the value by appearance with `@Environment(\.colorScheme)` as onboarding does, or dynamic `NSColor(name:dynamicProvider:)` bridged with `Color(nsColor:)`, but the hex values must be exactly these.

| Token | Dark | Light | Used for | New? |
|---|---|---|---|---|
| `background` | `#0D1210` (`darkBackground`) | `#F7F9F7` (`lightBackground`) | Window | existing |
| `text` | `#E8EDE9` (`darkText`) | `#14201B` (`lightText`) | Heading, typed text, secondary button label | existing |
| `mutedText` | `#8A9A92` (`sageGray`) | **`#55645C`** | Sub line, field label, placeholder, caption, disabled secondary label | light value new (see below) |
| `fieldFill` | `#151C18` | `#FFFFFF` | Field background | new |
| `fieldStroke` | `#6B7B73` | `#66766E` | Field border, secondary button border | new |
| `errorText` | **`#F0776A`** | `#C0392B` (the palette's danger red) | Error text and error icon | dark value new (see below) |
| `buttonFill` | `#2D8659` (`emerald`) | `#2D8659` | Primary button, focus stroke | existing |
| `buttonFillPressed` | `#26724C` | `#26724C` | Primary pressed | new |
| `disabledFill` | `#1E2823` | `#DDE4DF` | Disabled primary | new |
| `disabledLabel` | `#8A9A92` | `#55645C` | Disabled primary label (same as `mutedText`) | new alias |
| `successGlyph` | `#3D8168` | `#3D8168` | Check mark on the signed-in screen (a graphic, with text beside it) | the palette's success teal-green; not yet in `BrandColor` code |

Two palette values that cannot be used here as they are, and what replaces them. **The brand colour doc and `BrandColor` need updating by the founder or in a separate change; I did not edit `brand-color-system.md`.**

1. **`sageGray` `#8A9A92` as text on the light background is 2.79:1 (fails).** It passes on dark (6.41:1). Light mode uses `#55645C` (5.90:1 on the light background, 6.24:1 on white). Recommendation for the palette doc: sage is a dark-mode-only text colour; muted text is `#55645C` in light mode.
2. **The palette's danger red `#C0392B` as text on the dark background is 3.48:1 (fails).** It passes on light (5.14:1). Dark mode uses `#F0776A` (6.80:1). Recommendation: add `dangerOnDark = #F0776A` for text and icons; keep `#C0392B` for fills (white on it is 5.44:1).

Also noted, not changed: white on emerald is 4.5008:1, which passes by 0.0008. It holds for exact sRGB values, but any future edit to `emerald` or its rendering under a display profile could push it under. Optional, recommended: introduce `buttonFill = #297F53` (4.94:1 with white; 4.66:1 against the light background and 3.83:1 against the dark one, both above the 3:1 UI minimum). If adopted, the primary button and the focus stroke use it and the contrast test in section 8 stays green. Founder decision; this spec is written to work either way.

---

## 4. Steps

### 4.1 Step 1: email

Screen name in the model: `emailEntry`.

| Region | Content |
|---|---|
| Heading | `emailPrompt` |
| Sub line | `emailPrivacyNote` |
| Field label | `emailFieldLabel`; field placeholder `emailPlaceholder` |
| Field | Single line, 15 pt regular, `text`, left-aligned. Placeholder in `mutedText`. Text is not masked. |
| Status row | Empty, or one of the messages in 5. |
| Primary | `sendCodeButton`, loading label `sendingCode` |
| Secondary row | Empty, except `haveCodeButton` (340 wide) while a send is rate-limited (4.1.2). |
| Caption | Empty. |

**Field behaviour.** Autocorrect, spelling correction, text replacement, quote and dash substitution, data detectors and text completion off. No autofill or suggestions (the field editor's `isAutomaticTextCompletionEnabled` and the equivalent flags are `false`). Content type: email address (keyboard hint only). The field accepts any characters (validation happens on submit, 4.1.1); paste is trimmed of leading and trailing whitespace and newlines. Max 254 characters: input beyond it is ignored.

**Primary button states.**

| Condition | State |
|---|---|
| Field empty after trimming | Disabled |
| Non-empty, not busy, no cooldown for this address | Enabled |
| Send in flight | Loading (`sendingCode`), field read-only (not dimmed, caret hidden) |
| Send rate-limited for this exact address (case-insensitive) and now is before the cooldown end | Disabled, status row shows `resendCooldown` (muted, clock icon), `haveCodeButton` shown |

#### 4.1.1 Local validation (on submit, not while typing)

Trim leading and trailing whitespace and newlines. Invalid if: empty; longer than 254 characters; contains any whitespace or control character; contains no `@` or more than one `@`; empty text before or after the `@`. Invalid input does not call the server and shows `invalidEmail` in the status row. The check is deliberately loose (the server decides); it only catches typos that cannot be an address. A server `validation_failed` on send maps to the same `invalidEmail`.

#### 4.1.2 Rate-limited send

A 429 to a send means a code went to this address moments ago (possibly from a window the user closed). The status row shows `resendCooldown(retryAfter)` counting down (default 60 s), Send is disabled while the address is unchanged, and `haveCodeButton` appears so the user can type the code already in their inbox instead of waiting. Editing the field to a different address clears the cooldown state for the new text.

### 4.2 Step 2: code

Screen name: `codeEntry`.

| Region | Content |
|---|---|
| Heading | `codePrompt` |
| Sub line | `codeSentTo(email)`. Up to 2 lines, truncation in the middle, full text as the accessibility label and as the tooltip. |
| Field label | `codeFieldLabel`; placeholder `codePlaceholder` |
| Field | Single line, centred, 22 pt, monospaced digits (`.monospacedDigit()`), 2 pt letter spacing, `text`. Placeholder 15 pt `mutedText`. |
| Status row | Empty, or one message (5). |
| Primary | `signInButton` (see states), loading `verifyingCode` |
| Secondary row | Left `resendCodeButton`; right `changeEmailButton` |
| Caption | `resendCooldown(seconds)` with a clock icon while the resend cooldown runs; empty otherwise. |

**Field input rules.** The field holds ASCII digits 0 to 9 only. On every change, typed or pasted, drop every other character (spaces, hyphens of every kind, non-breaking spaces, letters, full-width digits), then keep at most the first 10 digits. This is a deliberate superset of "strip spaces and dashes on paste" in auth-design: a field that can only ever contain digits cannot be sent a stray character, and `vo.codeField.hint` says "Digits only". The caret ends up after the last digit. Same input-assist switches off as the email field, plus no autofill from Keychain or Contacts and no one-time-code suggestion. Never log or persist the digits. The digits are never shown anywhere but the field.

**Primary button states.**

| Condition | Primary |
|---|---|
| Fewer than 6 digits | `signInButton`, disabled |
| 6 to 10 digits, not busy, not locked out, not expired | `signInButton`, enabled |
| Verify in flight | `verifyingCode`, loading; field read-only |
| Locked out (rows 19, 20, 29 in 10.6) | `signInButton`, disabled |
| Code expired locally | The primary becomes `resendCodeButton` (emerald, enabled unless resending or in cooldown), and the secondary row shows only `changeEmailButton` in the right slot. The code field stays editable, but typing digits does not bring Sign in back. Reason: the only useful action is a new code, so it is the primary one and the sentence in the status row and the button agree. |

**Secondary buttons.**

| Button | Enabled when | While busy |
|---|---|---|
| `resendCodeButton` | Not in resend cooldown, no request in flight | Shows spinner plus `sendingCode` while a resend is in flight; disabled while a verify is in flight |
| `changeEmailButton` | Always, except while a verify is in flight | Disabled while verify or resend is in flight |

"Send a new code" returns to a fresh code step: field cleared, wrong-try counter zero, lockout cleared, a new 600 s timer and a new 60 s cooldown. The old code stops working (the server replaces it), and the VoiceOver hint says so. "Use a different email" returns to the email step with the address pre-filled and selected; the old code is discarded on the client. If the user then sends to the same address inside the cooldown they get 4.1.2, not a second email.

**Wrong tries.** The client counts `codeRejected` answers (a transient failure does not count). The fifth wrong answer starts a 30 s lockout (rows 19 and 29 in 10.6). The counter is in memory only and resets to zero when the lockout ends, when a new code is sent, and when the window closes. Supabase's own limit is the authority; if the server answers 429 to a verify before the fifth try, the same lockout state shows with the server's wait.

### 4.3 Step 3: signed in

Screen name: `signedIn`. Same frame; the field, status row, secondary row and caption are absent (their space stays empty).

| y | Content |
|---|---|
| 60 | `checkmark.circle.fill` SF Symbol, 40 pt, `successGlyph`, centred; hidden from VoiceOver (decorative, the text beside it carries the meaning) |
| 116 | Heading `signedIn`, 17 pt semibold, `text`, centred |
| 144 | `signedInAs(email)`, 13 pt regular, `mutedText`, centred, up to 2 lines, middle truncation |
| 248 | Primary button `doneButton`, the default button (Return activates it) |

The window does not close by itself: a confirmation that disappears is one a VoiceOver or slow reader can miss. Esc, Cmd-W, the close button and Done all close it. Focus is on the Done button.

### 4.4 Failure screen: session could not be saved

Screen name: `saveFailed`. Reached when the code was accepted but the Keychain write failed (`AuthError.storageFailed`). The verified session is held in memory in the model (never anywhere else) so a retry does not need a new code, which the server has already consumed. It is dropped when the window closes.

| y | Content |
|---|---|
| 60 | `exclamationmark.triangle.fill`, 32 pt, `errorText`, hidden from VoiceOver |
| 112 | `storageFailed`, 15 pt regular, `text`, centred, up to 3 lines (height 60). The text is in `text` rather than red: the icon and the words carry the meaning and the body stays readable. |
| 248 | Primary `retrySaveButton`, loading `savingSession` |

**Coordinator change this needs.** Today `AuthCoordinator.verifyCode` returns only `.failure(.storageFailed)` when the save fails, so the verified session is lost. To retry without a new code it must hand the session back on that failure (for example `.failure(.storageFailed)` plus the session in a separate return value) and expose `save(_ session:) -> Result<Void, AuthError>`. If that is not wanted, use the fallback in open question 3.

If the retry succeeds: go to `signedIn`. If it fails again: stay on this screen (no new message; the same text is still true). A retry after the user unlocks the Mac usually succeeds (a locked keychain is the common cause). On close, the model asks for a best-effort server logout of the unsaved session (capped at 3 s, as sign-out is) so the server session is not orphaned.

---

## 5. Errors and status messages

**Placement.** One status row (y 196, 36 high), directly under the field it concerns, left-aligned. It holds at most one message. The row is reserved, so a message never moves the button. Error icon: `exclamationmark.triangle.fill`, 13 pt medium, `errorText`, followed by the message in 13 pt regular `errorText`. Information (cooldown): `clock`, `mutedText`. The icon shape and the text, never colour alone, tell an error from a note.

**Priority when several apply (code step):** locked out, then expired, then `codeRejected`, then transport errors. The resend cooldown is not in the status row on the code step: it is the caption (y 330), so a lockout message and a cooldown can both be visible.

**Which message for which cause.**

| Cause | Copy key | Step | Style |
|---|---|---|---|
| Local email check failed, or server 400/422 `validation_failed` on send | `invalidEmail` | Email | Error |
| Verify answered `otp_expired` (403), or any code rejection | `codeRejected` | Code | Error |
| Local 600 s timer elapsed, or a rejection that arrives after it elapsed | `codeExpiredLocal` | Code | Error |
| Fifth wrong code, or server 429 `over_request_rate_limit` on verify | `tooManyAttempts(wait)` | Code | Error |
| Send 429 `over_email_send_rate_limit` | `resendCooldown(wait)` | Email (status row) / Code (caption) | Note |
| No network | `offline` | Either | Error |
| 10 s timeout | `timedOut` | Either | Error |
| 5xx, cannot connect, cannot parse the answer, `unavailable`, `unreachable`, `invalidResponse` | `serviceDown` | Either | Error |
| Keychain write failed | `storageFailed` | Failure screen | See 4.4 |

**Clearing rules.**

| Message | Clears when |
|---|---|
| `invalidEmail` | The user edits the field, or the next submit begins |
| `codeRejected`, `offline`, `timedOut`, `serviceDown` | The user edits the digits (or the email), or the next request begins |
| `codeExpiredLocal` | A new code is sent successfully, or the user goes back to the email step |
| `tooManyAttempts` | The lockout timer reaches zero, or a new code is sent successfully (the client counter resets; a server-side limit, if still active, will answer again) |
| `resendCooldown` on the email step | The timer reaches zero, or the address changes |

After `codeRejected` the digits stay in the field and are all selected, so typing replaces them; focus stays in the field. Every appearance fades in over 0.15 s, or appears instantly when Reduce Motion is on. There is no shake or other movement.

---

## 6. Keyboard and focus

| Key | Email step | Code step | Signed-in / failure |
|---|---|---|---|
| Return | Sends the code (when Send is enabled; otherwise nothing happens) | Signs in (when Sign in is enabled). When the code has expired locally, sends a new code (that is the primary button then) | Done / Try saving again |
| Esc | Closes the window | Closes the window | Closes the window |
| Cmd-W | Closes | Closes | Closes |
| Tab / Shift-Tab | Field, then the primary button | Field, primary, "Send a new code", "Use a different email" (skipping disabled ones) | Primary only |
| Space | Activates a focused button | same | same |
| Cmd-V | Pastes into the field | Pastes; the field filters (4.2) | n/a |

The primary button is the window's default button, so it draws as default and Return works from inside the field.

Initial focus: email step, the email field; code step, the code field (also after Send a new code and after Use a different email, which returns to the email field with its text selected); signed-in, the Done button. Focus never moves on a timer tick or when a message appears.

macOS caveat: unless System Settings, Keyboard, "Keyboard navigation" is on, Tab moves only between text fields, not buttons. The primary path does not depend on it: Return submits from the field, Esc closes. Optional accelerators for people who cannot use Tab to buttons: Cmd-R for "Send a new code" and Cmd-[ for "Use a different email" (the standard "back" key), attached as key equivalents on the buttons. If they do not fire in this accessory app, drop them: nothing else depends on them.

---

## 7. VoiceOver

Reading order is the visual order, top to bottom. Decorative icons and spinners are hidden.

| Element | Label | Value | Hint | Traits |
|---|---|---|---|---|
| Window | `windowTitle` | | | |
| Heading | The heading text | | | Header |
| Sub line | The sub line text (with the full email, never truncated) | | | Static text |
| Email field | `emailFieldLabel` | The text | `vo.emailField.hint` | Text field |
| Code field | `codeFieldLabel` | The digits | `vo.codeField.hint` | Text field |
| Status row (error) | `vo.errorPrefix` + ": " + message | | | Static text |
| Status row (note) | `vo.statusPrefix` + ": " + message | | | Static text |
| "Send code" | `sendCodeButton`, or `sendingCode` while busy | | `vo.sendCode.hint` | Button |
| "Sign in" | `signInButton`, or `verifyingCode` while busy | | `vo.signIn.hint` | Button |
| "Send a new code" | `resendCodeButton`, or `sendingCode` while busy | | `vo.resend.hint` | Button |
| "Use a different email" | `changeEmailButton` | | `vo.changeEmail.hint` | Button |
| "I already have a code" | `haveCodeButton` | | `vo.haveCode.hint` | Button |
| "Done" | `doneButton` | | `vo.done.hint` | Button |
| "Try saving again" | `retrySaveButton`, or `savingSession` | | `vo.retrySave.hint` | Button |
| Caption | The caption text (updated each second, so a focused caption reads the current value) | | | Static text |
| Confirmation group | `signedIn` | `signedInAs(email)` | | |

Disabled buttons are exposed as not enabled (VoiceOver says "dimmed"), which is correct and expected.

**Announcements** (`NSAccessibility.post(element:notification: .announcementRequested, userInfo:)`, with `.announcement` and, for errors, `.priority: NSAccessibilityPriorityLevel.high`):

| When | Text | Priority |
|---|---|---|
| Code step appears (send succeeded, resend succeeded) | `codeSentTo(email)` | high |
| A message appears in the status row | `vo.errorPrefix` + ": " + message | high |
| Lockout ends | `lockoutEnded` | medium |
| Resend cooldown ends (code step) | `resendReady` | medium |
| Sign-in succeeded | `signedIn` | high |
| Sign-out finished (from the menu) | `signedOut` | medium |

Never announce per tick of a countdown, and never announce the busy state (the button label changes and is read when focused). Colour is never the only carrier of meaning: each error has an icon and the "Error" prefix; the field's focus is a thicker stroke, not only a colour.

---

## 8. Accessibility and contrast checklist

Computed with the WCAG 2.x relative-luminance formula by a script (scratch: `d4d/contrast.py`, `d4d/table.py`), not estimated. Body-size text needs 4.5:1; non-text UI parts (field borders, focus indicator, button edges, glyphs) need 3:1. Disabled controls are exempt from WCAG but are reported and also pass.

### 8.1 Pairs in use

| Pair | Dark | Ratio | Light | Ratio | Min | Result |
|---|---|---|---|---|---|---|
| Body text on window background | `#E8EDE9` on `#0D1210` | 15.95 | `#14201B` on `#F7F9F7` | 15.85 | 4.5 | Pass |
| Muted text (sub line, labels, caption) on window background | `#8A9A92` on `#0D1210` | 6.41 | `#55645C` on `#F7F9F7` | 5.90 | 4.5 | Pass |
| Typed text on field fill | `#E8EDE9` on `#151C18` | 14.63 | `#14201B` on `#FFFFFF` | 16.77 | 4.5 | Pass |
| Placeholder (muted) on field fill | `#8A9A92` on `#151C18` | 5.88 | `#55645C` on `#FFFFFF` | 6.24 | 4.5 | Pass |
| Error text and icon on window background | `#F0776A` on `#0D1210` | 6.80 | `#C0392B` on `#F7F9F7` | 5.14 | 4.5 | Pass |
| Primary label, white on emerald | `#FFFFFF` on `#2D8659` | 4.50 (4.5008) | same | 4.50 (4.5008) | 4.5 | Pass, by 0.0008 (see section 3) |
| Primary label pressed, white on `#26724C` | | 5.84 | | 5.84 | 4.5 | Pass |
| Secondary button label on window background | `#E8EDE9` on `#0D1210` | 15.95 | `#14201B` on `#F7F9F7` | 15.85 | 4.5 | Pass |
| Disabled primary label on disabled fill (exempt) | `#8A9A92` on `#1E2823` | 5.15 | `#55645C` on `#DDE4DF` | 4.83 | 4.5 | Pass |
| Disabled secondary label on window background (exempt) | `#8A9A92` on `#0D1210` | 6.41 | `#55645C` on `#F7F9F7` | 5.90 | 4.5 | Pass |
| Field border vs window background (UI) | `#6B7B73` on `#0D1210` | 4.24 | `#66766E` on `#F7F9F7` | 4.53 | 3 | Pass |
| Field border vs field fill (UI) | `#6B7B73` on `#151C18` | 3.89 | `#66766E` on `#FFFFFF` | 4.79 | 3 | Pass |
| Secondary button border vs window background (UI) | `#6B7B73` on `#0D1210` | 4.24 | `#66766E` on `#F7F9F7` | 4.53 | 3 | Pass |
| Focus stroke (emerald) vs field fill (UI) | `#2D8659` on `#151C18` | 3.85 | `#2D8659` on `#FFFFFF` | 4.50 | 3 | Pass |
| Focus stroke (emerald) vs window background (UI) | `#2D8659` on `#0D1210` | 4.20 | `#2D8659` on `#F7F9F7` | 4.25 | 3 | Pass |
| Primary button fill vs window background (UI) | `#2D8659` on `#0D1210` | 4.20 | `#2D8659` on `#F7F9F7` | 4.25 | 3 | Pass |
| Success check glyph vs window background (UI) | `#3D8168` on `#0D1210` | 4.08 | `#3D8168` on `#F7F9F7` | 4.37 | 3 | Pass |

### 8.2 Existing palette pairs that fail, and the replacement used

| Pair | Ratio | Where it would have been used | Replacement |
|---|---|---|---|
| Sage `#8A9A92` on light `#F7F9F7` | 2.79 (fails 4.5) | Muted text in light mode | `#55645C`, 5.90 |
| Danger red `#C0392B` on dark `#0D1210` | 3.48 (fails 4.5) | Error text on dark | `#F0776A`, 6.80 |
| Emerald `#2D8659` as text on dark | 4.20 (fails 4.5) | Links or "Send a new code" as green text | Not used. Secondary actions are outlined buttons in `text`. |
| Emerald `#2D8659` as text on light | 4.25 (fails 4.5) | Same | Not used. |
| Forest `#1B4332` on dark | 1.71 (fails even 3:1) | Borders or text on dark | Not used. |
| Amber `#B8860B` on light | 3.08 (fails 4.5); white on amber 3.3 | Warnings | Not used on this window. |

Palette changes this spec needs (recorded here, not made in `brand-color-system.md`): add `mutedText` light `#55645C`; add `dangerOnDark` `#F0776A`; add `fieldFill`, `fieldStroke`, `buttonFillPressed`, `disabledFill` (table in section 3); state that sage is not for text on light. Optional: `buttonFill` `#297F53` for margin.

### 8.3 Contrast unit test

Add `Tests/OpenWisprTests/ContrastTests.swift`: a small `relativeLuminance` and `contrastRatio(hexA, hexB)` helper, and one assertion per row of 8.1 with its minimum (4.5 for text pairs, 3 for the UI rows), for both appearances, reading the hex values from the same tokens the views use, never from a copy. Fix the token, not the test.

### 8.4 Checklist

- [ ] Every text and UI colour pair on this window is in 8.1 and passes.
- [ ] Both appearances checked with real screenshots: email, code (with an error, with a lockout, expired, cooldown), signed in, save failed. Saved under `docs/design/screens/` (I could not produce them: see the last section).
- [ ] Every control is reachable by keyboard (Tab between fields; Return and Esc always work).
- [ ] Every control has a VoiceOver label; buttons have hints (section 7); decorative icons and spinners are hidden.
- [ ] No meaning by colour alone: errors have an icon and a spoken "Error"; focus is a thicker stroke; disabled looks different by fill and label, not only tint.
- [ ] Reduce Motion: the only animation is the 0.15 s fade, replaced by no animation.
- [ ] Increase Contrast and Reduce Transparency: nothing here uses transparency for meaning (the only alpha is on pressed and disabled outlines, which have a text label as well).
- [ ] Nothing is styled in brand green except the primary button fill and the focus stroke; no green text.
- [ ] Copy lint test present and green (`sign-in-copy.md`, section 7).

---

## 9. DEBUG menu items

Compiled only under `#if DEBUG` in `StatusBarController.buildMenu()`, directly after "Grant/Revoke rewrite consent (dev)". They replace the two items "Paste dev session token from clipboard" and "Clear dev session token", which are removed (auth-design section 3). The menu is rebuilt (`buildMenu()`) whenever the session changes (sign-in success, sign-out).

| Session state (`SessionStore.load()`) | Items, in order | Titles (exact) |
|---|---|---|
| `.success(nil)` (signed out) | One enabled item | `menuSignIn`: "Sign in…" |
| `.success(session)` (signed in) | A disabled item, then an enabled item | `menuSignedInAs`: "Signed in as <email>" (the email truncated in the middle to 40 characters with "…"; the full address as the item's tooltip); `menuSignOut`: "Sign out" |
| `.failure` (keychain unreadable, for example locked) | One disabled item, so the app does not claim to be signed out | "Sign-in status unavailable" (`menuSignInUnavailable`, in the copy file) |

Actions. "Sign in…": `SignInWindowController.shared.show()` (section 1.1). "Sign out": call `AuthCoordinator.signOut()`, which clears the Keychain item first, lifts the rewrite stop, then makes the best-effort server logout (capped at 3 s). If `local` is `.success`: rebuild the menu, `showNotice(signOutSignedOutNotice)` (5 s, existing behaviour) and post the `signedOut` announcement. If `local` is `.failure(.storageFailed)` the token is still on this Mac: rebuild the menu (it still shows "Signed in as…"), `showNotice(signOutFailed)`, and post no `signedOut` announcement. No confirmation: it is reversible and low stakes. No key equivalents on any of the three. Release builds contain none of them until Day 16.

---

## 10. State machine

Implement as a pure model, `SignInModel`, with an injected clock, so it can be unit-tested with no UI and no network. The view renders the model; the model never touches AppKit. Suggested shape:

```
mutating func handle(_ event: SignInEvent, now: Date) -> [SignInEffect]
```

### 10.1 Context (held alongside the state)

| Field | Meaning |
|---|---|
| `email` | Trimmed address as entered. |
| `digits` | Digits currently in the code field (0 to 10). |
| `status` | `nil`, or one of `invalidEmail`, `codeRejected`, `codeExpiredLocal`, `tooManyAttempts(until)`, `offline`, `timedOut`, `serviceDown`, `resendCooldown(until)`. |
| `attempts` | Wrong codes since the last reset, 0 to 5. |
| `codeSentAt` | Date the last successful send was requested (the request start, not the response, so the client expires slightly early rather than late). |
| `resendAvailableAt`, `resendEmail` | End of the send cooldown and the address it applies to. |
| `lockedUntil` | End of the lockout, or nil. |
| `pendingSession` | The verified session while on `saveFailed`, else nil. Never persisted. |
| `generation` | Integer bumped whenever a request is started or the window closes. |

### 10.2 States

| State | Meaning |
|---|---|
| `emailEntry` | Step 1, idle. |
| `sendingCode(origin)` | A send request is in flight; `origin` is `.email` (from step 1) or `.resend` (from step 2). |
| `codeEntry` | Step 2, idle. |
| `verifying` | A verify request is in flight. |
| `saving` | Writing the verified session to the Keychain (synchronous; a state so the tests can see it). |
| `saveFailed` | Keychain write failed; `pendingSession` held. |
| `signedIn` | Success screen. |
| `closed` | Terminal. |

### 10.3 Events

`emailEdited(text)`, `submitEmail`, `sendSucceeded`, `sendFailed(AuthError)`, `codeEdited(text)`, `submitCode`, `verifySucceeded(session)`, `verifyFailed(AuthError)`, `resendTapped`, `changeEmailTapped`, `haveCodeTapped`, `saveSucceeded`, `saveFailed`, `retrySaveTapped`, `tick`, `closeRequested` (Esc, Cmd-W, close button, Done).

### 10.4 Effects

`requestCode(email)`, `verifyCode(email, digits)`, `storeSession(session)`, `clearPasteboardIfItHoldsTheCode`, `resetRewriteSession`, `announce(text, priority)`, `focus(field)`, `logoutBestEffort(session)`, `stopTimers`, `closeWindow`.

### 10.5 Error mapping

`wait` = `max(1, ceil(retryAfter))` seconds. `AuthService` has already replaced a missing or unusable `Retry-After` with `AuthError.defaultRetryAfter` (60), so the model never needs its own default.

`AuthError` to status. One function, no `default`, so a new `AuthError` case does not compile until it is placed.

| `AuthError` | On send | On verify |
|---|---|---|
| `invalidEmail` | `invalidEmail` | `serviceDown` (the client already validated; an answer like this means something is off, and it does not count as a try) |
| `codeRejected` | `serviceDown` (cannot happen on send) | `codeRejected` (or `codeExpiredLocal` if the local timer has elapsed); attempts + 1 |
| `tooManyAttempts(retryAfter)` | `resendCooldown(wait)` | `tooManyAttempts(wait)`, lockout until now + wait |
| `sendRateLimited(retryAfter)` | `resendCooldown(wait)` | `serviceDown` (cannot happen on verify) |
| `offline` | `offline` | `offline` |
| `timedOut` | `timedOut` | `timedOut` |
| `unreachable`, `unavailable`, `invalidResponse` | `serviceDown` | `serviceDown` |
| `storageFailed` | n/a | Raised when the verified session could not be saved (`AuthCoordinator.verifyCode` returns it): goes to `saveFailed` (rows 14 to 16) |
| `cancelled` | Back to the idle step, no message, no counter change (it is not a failure; the window only cancels when it closes) | Same |
| `sessionRevoked` | n/a (Day 5, not raised by the window) | n/a |

Transport failures (`offline`, `timedOut`, `serviceDown`) never change `attempts`, never start a cooldown and never clear the digits.

### 10.6 Transition table

Rules that apply to every row: a result event (`sendSucceeded`, `sendFailed`, `verifySucceeded`, `verifyFailed`) whose generation does not match the current one is dropped without any change; any event received in `closed` is ignored; `closeRequested` from any state goes to `closed` with `stopTimers`, `closeWindow`, and, if a request is in flight, the in-flight result is dropped by the generation rule (a session that arrives after closing is never stored).

| # | State | Event | Guard | Next state | Context changes and effects |
|---|---|---|---|---|---|
| 1 | `emailEntry` | `emailEdited` | | `emailEntry` | Trim and store text; clear `status` unless it is a `resendCooldown` for the same address |
| 2 | `emailEntry` | `submitEmail` | trimmed text empty | `emailEntry` | No-op (the button is disabled) |
| 3 | `emailEntry` | `submitEmail` | local check fails (4.1.1) | `emailEntry` | `status = invalidEmail`; `announce`; no request |
| 4 | `emailEntry` | `submitEmail` | valid and `resendAvailableAt > now` and same address as `resendEmail` | `emailEntry` | No-op (the button is disabled) |
| 5 | `emailEntry` | `submitEmail` | valid otherwise | `sendingCode(.email)` | `email` set; `status = nil`; `generation += 1`; stamp `requestedAt = now`; `requestCode` |
| 6 | `sendingCode(.email)` | `sendSucceeded` | | `codeEntry` | `codeSentAt = requestedAt`; `resendAvailableAt = now + 60`, `resendEmail = email`; `attempts = 0`; `lockedUntil = nil`; `digits = ""`; `status = nil`; `focus(code)`; `announce(codeSentTo)` |
| 7 | `sendingCode(.email)` | `sendFailed(e)` | e maps to `resendCooldown` | `emailEntry` | `status = resendCooldown(until)`; `resendAvailableAt = now + wait`; `resendEmail = email` |
| 8 | `sendingCode(.email)` | `sendFailed(e)` | any other e | `emailEntry` | `status` per 10.5; `announce`; `focus(email)` |
| 9 | `emailEntry` | `haveCodeTapped` | `status` is `resendCooldown` | `codeEntry` | `codeSentAt = now` (unknown, so the server stays the authority for expiry); `resendAvailableAt` kept; `attempts = 0`; `digits = ""`; `status = nil`; `focus(code)` |
| 10 | `codeEntry` | `codeEdited(text)` | | `codeEntry` | `digits = filter(text)` (ASCII digits, first 10); clear `status` unless it is `tooManyAttempts` or `codeExpiredLocal` |
| 11 | `codeEntry` | `submitCode` | `digits.count < 6` or `lockedUntil > now` | `codeEntry` | No-op |
| 12 | `codeEntry` | `submitCode` | `now >= codeSentAt + 600` | `codeEntry` | `status = codeExpiredLocal`; no request; `announce` |
| 13 | `codeEntry` | `submitCode` | otherwise | `verifying` | `status = nil`; `generation += 1`; `verifyCode(email, digits)` |
| 14 | `verifying` | `verifySucceeded(s)` | | `saving` | `storeSession(s)` (then `saveSucceeded` or `saveFailed`) |
| 15 | `saving` | `saveSucceeded` | | `signedIn` | `clearPasteboardIfItHoldsTheCode`; `resetRewriteSession`; `digits = ""`; `stopTimers`; `focus(done)`; `announce(signedIn)` |
| 16 | `saving` | `saveFailed` | | `saveFailed` | `pendingSession = s`; `announce(storageFailed)`; `focus(retry)` |
| 17 | `verifying` | `verifyFailed(codeRejected)` | `now >= codeSentAt + 600` | `codeEntry` | `status = codeExpiredLocal`; `announce` |
| 18 | `verifying` | `verifyFailed(codeRejected)` | `attempts + 1 < 5` | `codeEntry` | `attempts += 1`; `status = codeRejected`; select all digits; `announce` |
| 19 | `verifying` | `verifyFailed(codeRejected)` | `attempts + 1 == 5` | `codeEntry` | `attempts = 5`; `lockedUntil = now + 30`; `status = tooManyAttempts(30)`; `announce` |
| 20 | `verifying` | `verifyFailed(tooManyAttempts(w))` | | `codeEntry` | `lockedUntil = now + w`; `status = tooManyAttempts(w)`; `announce` |
| 21 | `verifying` | `verifyFailed(offline / timedOut / unreachable / unavailable / invalidResponse / invalidEmail)` | | `codeEntry` | `status` per 10.5; attempts, digits and timers unchanged; `announce` |
| 22 | `codeEntry` | `resendTapped` | `resendAvailableAt <= now` | `sendingCode(.resend)` | `status` kept only if `tooManyAttempts`; `generation += 1`; stamp `requestedAt = now`; `requestCode(email)` |
| 23 | `codeEntry` | `resendTapped` | `resendAvailableAt > now` | `codeEntry` | No-op (the button is disabled) |
| 24 | `sendingCode(.resend)` | `sendSucceeded` | | `codeEntry` | Same as row 6 (new timer, new cooldown, counter and lockout reset, digits cleared) |
| 25 | `sendingCode(.resend)` | `sendFailed(e)` | e maps to `resendCooldown` | `codeEntry` | `resendAvailableAt = now + wait`; the caption shows it; old code and timer unchanged |
| 26 | `sendingCode(.resend)` | `sendFailed(e)` | any other e | `codeEntry` | `status` per 10.5; `announce`; timers unchanged (a failed send must not start a cooldown, and the old code may still be valid) |
| 27 | `codeEntry` | `changeEmailTapped` | | `emailEntry` | `digits = ""`; `attempts = 0`; `lockedUntil = nil`; `status = nil`; `resendAvailableAt`/`resendEmail` kept; `focus(email)` with the text selected |
| 28 | `codeEntry` | `tick` | `status` is not `codeExpiredLocal` and `now >= codeSentAt + 600` | `codeEntry` | `status = codeExpiredLocal`; `announce` |
| 29 | `codeEntry` | `tick` | `lockedUntil != nil` and `now >= lockedUntil` | `codeEntry` | `lockedUntil = nil`; `attempts = 0`; clear `tooManyAttempts` status; `announce(lockoutEnded)` |
| 30 | `codeEntry` | `tick` | `resendAvailableAt` just passed | `codeEntry` | `announce(resendReady)` (once) |
| 31 | `emailEntry` | `tick` | `status` is `resendCooldown` and `now >= resendAvailableAt` | `emailEntry` | Clear `status` (Send re-enables, `haveCodeButton` hides) |
| 32 | `verifying`, `sendingCode` | `tick` | | same | Countdowns still update; expiry and lockout transitions (28 to 30) are applied when the request ends, never over a busy state |
| 33 | `saveFailed` | `retrySaveTapped` | | `saving` | `storeSession(pendingSession)` |
| 34 | `saving` (from retry) | `saveFailed` | | `saveFailed` | Same screen; no new announcement |
| 35 | `signedIn` | `closeRequested` | | `closed` | `closeWindow` |
| 36 | `saveFailed` | `closeRequested` | | `closed` | `logoutBestEffort(pendingSession)`; drop `pendingSession` |
| 37 | any except `signedIn`, `saveFailed` | `closeRequested` | | `closed` | `stopTimers`; `closeWindow`; drop email, digits, counters |

Notes on the ones that were named in the brief: "email invalid" is rows 3 and 8; "sending" is `sendingCode` and `verifying`; "code sent" is row 6; "code wrong or expired" is rows 17 and 18; "too many attempts lockout" is rows 19, 20, 29; "resend cooldown" is rows 7, 9, 25, 30, 31; "offline" and "service down" are the 10.5 mapping in rows 8, 21, 26; "storage failure" is rows 16, 33, 34, 36; "success" is row 15; "cancel at each step" is rows 35 to 37; "code expired locally after 10 minutes" is rows 12, 17 and 28.

### 10.7 Timers

One repeating timer at 1 Hz, running only while the window is open and `codeEntry` or a cooldown status is showing; it sends `tick`. Everything is computed from `Date` values, never from a decrementing counter, so sleep and wake, and a background app being throttled, produce the right remaining time. On a tick the view recomputes `ceil(remaining)` for the countdown text. Use the injected clock in tests: advancing it by 600 s must flip the state without any real waiting.

### 10.8 Suggested unit tests

1. Valid address, send succeeds: `emailEntry` to `sendingCode` to `codeEntry`, one `requestCode`, `codeSentAt` equals the request start.
2. Invalid addresses (no `@`, two `@`, space inside, 255 characters, `a@`, `@a`) never emit `requestCode`.
3. Digits filter: `"123 456"`, `"123-456"`, `"12a3456"` all give `"123456"`; 12 digits give the first 10.
4. Submit is a no-op with 5 digits and with 6 digits during lockout; 6 to 10 digits submits.
5. Wrong code four times: status `codeRejected` each time, attempts 4; the fifth gives `tooManyAttempts(30)` with `lockedUntil = now + 30`; `submitCode` during the lockout emits nothing; at `now + 30` the tick clears it and resets attempts.
6. Server 429 on verify (retryAfter 45) locks for 45; without `Retry-After` for 60.
7. Wrong code after 600 s gives `codeExpiredLocal`, not `codeRejected`; a submit after 600 s emits no `verifyCode`.
8. Tick at `codeSentAt + 600` sets `codeExpiredLocal` while idle, and not while `verifying`.
9. Transient failures (`offline`, `timedOut`, `unavailable`, `invalidResponse`) leave attempts, digits and timers unchanged.
10. Resend: guard by `resendAvailableAt`; success resets counter, lockout and timer; 429 sets the cooldown and keeps the old code state; a failed resend starts no cooldown.
11. Send 429 on step 1 shows the cooldown, disables Send for that address only, offers `haveCodeTapped`, which enters `codeEntry`.
12. Change email keeps the cooldown for the old address.
13. Verify success then `saveFailed`: `pendingSession` set, retry succeeds, and `closeRequested` from `saveFailed` emits `logoutBestEffort` and clears the session.
14. `closeRequested` while `verifying`, then a late `verifySucceeded`: no `storeSession`, no state change.
15. Every `AuthError` case maps to a status on send and on verify (exhaustive switch).

---

## 11. What I could not verify

I cannot run the app, so none of the following has been seen on a screen:

- Screenshots for both appearances, and how the custom field and button styles render against the real title bar. The definition of done asks for them under `docs/`; they must be taken from the built window (`docs/design/screens/`, one per state and appearance).
- That the minimal main menu (1.2) is enough for Cmd-V, Cmd-A and Cmd-W to work in an `.accessory` app. This is the standard workaround, but it is the first thing to test.
- That focus lands in the field on first show from a menu click (1.1 step 1), on the current macOS.
- That SwiftUI `keyboardShortcut` or `NSButton.keyEquivalent` fires for Cmd-R and Cmd-[ without a menu item (they are optional).
- How VoiceOver reads the digit field (it may read the value as one number rather than digit by digit; if so, set the accessibility value to the digits separated by spaces).
- The 4.5008:1 primary-button margin under a real display profile.
- Real Supabase behaviour: whether a 429 carries `Retry-After`, the real error codes for a wrong versus expired code, and the OTP length and lifetime (all VERIFY-ON-DAY-16 in auth-design). The copy and this spec are written so that none of them changes a string except `codeSentTo` (lifetime) and `codePlaceholder` (length).

Open questions for the founder:

1. **Floating window.** With the normal window level, the window can be covered by the mail app while the user reads the code, and the way back is the menu bar item. A floating level would keep it visible above Mail but also above everything else. I chose normal; say if you want floating.
2. **Brand token changes** in section 3 (light muted text, dark error red, four neutrals, optionally a darker button fill) and their addition to `brand-color-system.md`.
3. **Retry without a new code** on a save failure (4.4) means the verified session sits in memory for the life of that screen. If security prefers no session in memory after a failed save, the fallback is: the failure screen offers `resendCodeButton` as primary instead, and rows 33 to 34 are dropped.
4. **Dictation while the window is key.** The global hotkey still works, and the dictated text would be inserted into whichever app is frontmost, which is this window's field. Not handled here; worth a decision if it turns out to be a nuisance.
