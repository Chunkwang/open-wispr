# Sign-in copy

Every user-visible string of the sign-in window, its DEBUG menu items and the sign-out notice. Companion to `docs/design/sign-in.md` (layout, states, contrast). Keys are the names from `docs/auth-design.md` section 6; the engineer implements them in `SignInCopy.swift` with exactly these texts.

Voice source: `brand-voice-tone-guide.md`. Tone for this surface: errors are calm, specific and never apologise; the permission-and-confirmation limit of two sentences applies to every message here. Nothing in this file teases anything that does not ship today.

## Conventions

- Text is verbatim. Use the straight apostrophe `'` in source, as `RewriteNotices.swift` does. The ellipsis in "Sign in…" and "Sending code…" is the single character U+2026.
- `\(email)` is the address the user entered, trimmed, as typed (case preserved). It is inserted verbatim, never shortened inside the string. The view truncates on screen (see `sign-in.md`), the string does not.
- `\(secs)` is produced by `secondsPhrase(waitSeconds)`: `1` gives "1 second"; 2 to 120 gives "N seconds"; more than 120 gives "M minutes" with M = waitSeconds rounded up to whole minutes (Supabase can rate-limit for an hour, and "3600 seconds" is not readable). `waitSeconds` below 1 is treated as 1.
- Two categories, linted differently (see "What the copy lint test should assert"): **message** (a full sentence or two, ends with a full stop) and **label** (button, field label, menu title, progress text: no full stop).
- No string reveals whether an account exists. Sign-in creates the account on first use, so every message reads the same for a new and an existing address. None of these strings contains the words "account", "register", "sign up" or "exists".

## 1. Messages (the keys in auth-design section 6)

| Key | Text | Where it appears | Tone note |
|---|---|---|---|
| `emailPrompt` | `Enter your email address. We'll send you a code to sign in.` | Email screen, heading (17 pt), above the field. | Says what happens next and what the user gets. "Sign in", never "log in", to match the menu ("Rewrite: needs sign-in"). |
| `sendingCode` | `Sending code…` | Label of the primary button while the code request is in flight (spinner plus this text). Also the VoiceOver label of the busy button. | Progress text, so it is a label, not a message. Present tense, no "please wait". |
| `codeSentTo(email)` | `Code sent to \(email). It expires in 10 minutes.` | Code screen, sub line under the heading. Also posted as the VoiceOver announcement when the code screen appears. | The 10 must come from the same constant that drives the local expiry timer (`codeLifetimeSeconds` = 600), not be typed twice. If Day 16 finds the real project cannot be set to 600 s, change the constant and this string together. Says "sent", which is true whether or not the address had an account. |
| `codePrompt` | `Enter the code from the email.` | Code screen, heading (17 pt). | Names the object ("the code from the email"). Digit count is not stated because OTP length is configurable (6 to 10, VERIFY-ON-DAY-16); the placeholder says 6 and is the one place to change. |
| `signedIn` | `You're signed in.` | Signed-in confirmation, heading (17 pt semibold). Also the VoiceOver announcement on success. | A plain fact. No exclamation mark: this is a security state change, not a moment of delight. The address is shown on its own line below (see `signedInAs`). |
| `signedOut` | `You're signed out.` | State statement used where the app must say it is signed out without an instruction: the VoiceOver announcement posted after Sign out, and the tooltip of the menu bar item's status line if the engineer adds one. | Short on purpose so VoiceOver is not verbose. Deliberately the same first sentence as `sessionRevoked` and the existing rewrite notice, so the app says one thing in one way. |
| `signOutSignedOutNotice` | `Signed out. Dictation still works; sign in to use rewrite.` | Five-second menu notice (`StatusBarController.showNotice`) after the user chooses Sign out. | Says what happened, then the honest consequence: dictation is unaffected, rewrite needs a sign-in. True today, since rewrite falls back to the raw transcript when signed out. |
| `invalidEmail` | `That email address doesn't look valid. Check it and try again.` | Email screen, status row under the field. Shown for the local check failing and for a server `validation_failed` on the send. | "Doesn't look valid" is honest: the client check is loose (one @, no whitespace, at most 254 characters) and the server is the authority. Does not blame the user. |
| `codeRejected` | `That code is wrong or has expired. Check the latest email or send a new code.` | Code screen, status row under the field. | ONE string for wrong and expired, because the server cannot tell them apart and we must not guess. "Latest" is a real instruction: a new code invalidates the old one, so an older email is the usual cause. |
| `codeExpiredLocal` | `This code has expired. Send a new code.` | Code screen, status row, when the local 600 s timer runs out (no server call), and when a rejected code comes back after the timer already ran out. | Unlike `codeRejected`, we know for certain here, so we say "has expired". The primary button becomes "Send a new code" (see `sign-in.md`), so the sentence and the button agree. |
| `tooManyAttempts(waitSeconds)` | `Too many attempts. Try again in \(secs), or send a new code.` | Code screen, status row, during the 30 s lockout after 5 wrong codes, and during a server 429 on verify (wait taken from Retry-After, default 60). | "Attempts", not "incorrect codes": a server 429 does not tell us the codes were wrong. Gives the number, and the alternative action. |
| `resendCooldown(waitSeconds)` | `You can request a new code in \(secs).` | Code screen: caption under the secondary buttons while "Send a new code" is disabled. Email screen: status row when the server answered 429 to a send. | Muted info line, not an error, so it uses the muted colour with a clock symbol, never the error colour. Same wording in both places because it is the same fact. |
| `offline` | `You're offline, and sign-in needs a connection. Try again once you're back online.` | Status row of either screen when the request fails with no network. | Mirrors the existing rewrite wording ("You're offline, and rewrite needs a connection"). |
| `timedOut` | `The sign-in service didn't answer in time. Try again.` | Status row of either screen when the 10 s request timeout fires. | States the observed fact. Does not say "unreachable" (untrue: we may have reached it). |
| `serviceDown` | `The sign-in service isn't working as expected. Try again in a few minutes.` | Status row of either screen for 5xx, cannot-connect, and an answer we cannot parse. | Covers three causes with one sentence that is true for all three, so it does not claim "couldn't reach" (untrue for a 5xx or a bad body). Compare `RewriteNotices.swift`, which splits the same cases for the same reason. |
| `storageFailed` | `Your code was accepted, but this Mac wouldn't let the app save the sign-in. Try saving again.` | Save-failure screen (see `sign-in.md`), body text, under an error icon. | Honest and specific: the server said yes, the Keychain said no, and the user is not signed in yet. The action names what the button does ("Try saving again"). It does not say "signed in", because the app is not. |
| `signOutFailed` | `Couldn't remove your sign-in from this Mac. You're still signed in.` | Five-second menu notice when Sign out fails because the Keychain refused to delete the session (`AuthCoordinator.signOut().local == .failure(.storageFailed)`). | Not in the auth-design key list; added because the coordinator can report this and the UI must never claim the user is signed out while the token is still on the Mac. States the real outcome in the second sentence. No apology. |
| `sessionRevoked` | `You're signed out. Sign in to keep using rewrite.` | Day 5, menu notice when a refresh fails permanently or the proxy keeps answering 401. | Verbatim from `docs/auth-design.md` and the implementation plan; the first sentence matches `RewriteError.unauthorized`'s notice. Not used on Day 4. |

## 2. Window text that is not a message

| Key | Text | Where it appears | Tone note |
|---|---|---|---|
| `windowTitle` | `Sign in` | Title bar. | Names the window's job. No product name: it survives the rename. |
| `emailPrivacyNote` | `Your email address goes to our sign-in service and its email provider to deliver the code.` | Email screen, sub line under the heading (13 pt, muted). | The voice guide's "say exactly what data moves". It is the plain-language line for the `TRUST.md` inventory entry. Nothing else is claimed about retention. |
| `signedInAs(email)` | `Signed in as \(email).` | Signed-in confirmation, sub line, and the VoiceOver value of the confirmation group. | A statement, so it takes a full stop. On screen the line shows this text and truncates in the middle at two lines. |
| `lockoutEnded` | `You can try the code again.` | VoiceOver announcement only, posted once when the lockout timer reaches zero. | Polite priority. Not shown visually: the error row simply clears. |
| `resendReady` | `You can request a new code now.` | VoiceOver announcement only, posted once when the resend cooldown reaches zero. | Same as above. |
| `verifyingCode` | `Checking code…` | Label of the primary button while the code is being verified (spinner plus text). | Progress text (label). "Checking", not "verifying", which is jargon. |
| `savingSession` | `Saving sign-in…` | Label of the primary button while a save retry is running. | Progress text (label). |

## 3. Field labels and placeholders

| Key | Text | Where it appears | Tone note |
|---|---|---|---|
| `emailFieldLabel` | `Email address` | 12 pt label above the email field, and the field's VoiceOver label. | A visible label, not only a placeholder: placeholders vanish while typing. |
| `emailPlaceholder` | `you@example.com` | Placeholder inside the email field. | An obviously fake address on the reserved example domain. |
| `codeFieldLabel` | `Sign-in code` | 12 pt label above the code field, and the field's VoiceOver label. | |
| `codePlaceholder` | `6-digit code` | Placeholder inside the code field. | The one string to change if OTP length changes on Day 16. Submit still enables at 6 to 10 digits. |

## 4. Buttons

Labels name the real action (voice guide: "Run command" beats "Continue"). Sentence case, no full stop.

| Key | Text | Where it appears | Tone note |
|---|---|---|---|
| `sendCodeButton` | `Send code` | Email screen, primary button. | The action is sending the code, not "Continue" or "Next". |
| `signInButton` | `Sign in` | Code screen, primary button. | |
| `resendCodeButton` | `Send a new code` | Code screen, secondary button (left). Becomes the primary button when the code has expired locally. | Exact label from auth-design. The hint tells VoiceOver users that the old code stops working. |
| `changeEmailButton` | `Use a different email` | Code screen, secondary button (right). | Exact label from auth-design. |
| `haveCodeButton` | `I already have a code` | Email screen, secondary button, shown ONLY while the send is rate-limited (the server answered 429, so a recent code exists). | Removes the dead end where the user closed the window, reopened it and cannot request another code for a minute although the code is in their inbox. |
| `doneButton` | `Done` | Signed-in confirmation, primary button. | Closes the window. |
| `retrySaveButton` | `Try saving again` | Save-failure screen, primary button. | Names the action: it retries the Keychain write with the verified session held in memory. |

## 5. Menu items (DEBUG builds only, until Day 16)

Menu titles are labels, not sentences. Follow the existing menu style: sentence case.

| Key | Text | Where it appears | Tone note |
|---|---|---|---|
| `menuSignIn` | `Sign in…` | Enabled item while signed out. Opens (or raises) the sign-in window. | Trailing ellipsis (U+2026) because it opens a window that needs more input, per macOS convention. |
| `menuSignedInAs(email)` | `Signed in as \(email)` | Disabled item while signed in. | No full stop (it is a menu title). The view truncates the email in the middle to 40 characters with "…" and puts the full address in the item's tooltip. |
| `menuSignOut` | `Sign out` | Enabled item while signed in, directly below the disabled item. | No ellipsis: it acts immediately and is reversible (sign in again), so no confirmation. |
| `menuSignInUnavailable` | `Sign-in status unavailable` | Disabled item shown instead of the two above when the Keychain cannot be read (for example while the Mac is locked), so the menu does not claim the user is signed out. | States the limit plainly and takes no action. Label, no full stop. |

## 6. VoiceOver strings

Labels are the field or button text above (same key, same string) unless listed here. Hints describe the result of activating a control, in one sentence, and are never the same words as the label.

| Key | Text | Applies to | Tone note |
|---|---|---|---|
| `vo.emailField.hint` | `Type the address to send the code to.` | Email field | |
| `vo.sendCode.hint` | `Sends a sign-in code to this address.` | "Send code" button | |
| `vo.codeField.hint` | `Type the code from the email. Digits only.` | Code field | Two short sentences, the second because the field silently drops other characters. |
| `vo.signIn.hint` | `Checks the code and signs you in.` | "Sign in" button | |
| `vo.resend.hint` | `Sends a new code. The old code stops working.` | "Send a new code" button | The consequence the user needs before pressing. |
| `vo.changeEmail.hint` | `Goes back to enter another address.` | "Use a different email" button | |
| `vo.haveCode.hint` | `Skips sending and goes to code entry.` | "I already have a code" button | |
| `vo.done.hint` | `Closes this window.` | "Done" button | |
| `vo.retrySave.hint` | `Tries again to save your sign-in on this Mac.` | "Try saving again" button | |
| `vo.errorPrefix` | `Error` | Prefix of the status row's VoiceOver label: "Error: <message>". The icon is hidden from VoiceOver. | A label (no full stop). Colour is never the only signal: the row also has an icon and this prefix. |
| `vo.statusPrefix` | `Note` | Same, for the muted informational row (cooldown, lockout ended). | A label. |

## 7. What the copy lint test should assert

Add `Tests/OpenWisprTests/SignInCopyTests.swift` in the style of `RewriteNoticeTests`. Reuse its `banned` list and `sentenceCount` (move them to a small shared test helper rather than copying them a second time). The strings under test are produced by `SignInCopy`, rendered with fixed samples: `email = "sam@example.com"`, and `waitSeconds` in `[1, 2, 30, 60, 120, 121, 3600]`.

**Every string (message or label):**
1. No `!` anywhere.
2. Lower-cased text contains none of: `smart`, `seamless`, `powerful`, `magic`, `simply`, `oops`, `just`, `sorry`, `apolog`, `unfortunately` (the existing list; it is a substring match, so words such as "adjust" and "justify" are caught too, which is fine).
3. Contains none of these account-existence words: `account`, `register`, `sign up`, `signup`, `exist`, `not found`, `no user`.
4. Contains no digit run of 6 or more (a code or token must never be in copy) and no `http`.
5. Not empty, no leading or trailing whitespace, no doubled spaces, no `\n`.
6. Ellipsis, if present, is the single character `…`, never `...`.

**Messages** are every row of sections 1 and 2 except the labels `windowTitle`, `sendingCode`, `verifyingCode` and `savingSession`, plus every `vo.*.hint` row of section 6:
7. `sentenceCount` between 1 and 2 inclusive (the existing counter counts `.` and `?` followed by a space or the end of the string).
8. At most 120 characters after rendering with the sample email (the existing notice ceiling; these also appear on one menu line). The email is the only unbounded input, so the limit applies to the template with the sample address; the view is responsible for wrapping and truncating long real addresses.
9. Ends with `.` (no other terminal punctuation, so no `?` and no `…`).
10. Only `codeSentTo`, `signedInAs` and `menuSignedInAs` may render `sam@example.com`.

**Labels** are everything else: sections 3, 4 and 5, the four progress and title strings named above, `vo.errorPrefix` and `vo.statusPrefix`:
11. At most 30 characters after rendering with the sample email, and no full stop.

**Specific behaviours:**
12. `codeRejected` is the only string used for both wrong and expired codes: the model test, not the copy test, asserts that a 403 `otp_expired` maps to `codeRejected` (or to `codeExpiredLocal` only when the local timer has already run out).
13. `codeSentTo` contains `"\(codeLifetimeSeconds / 60) minutes"`, so the copy and the constant cannot drift.
14. `secondsPhrase`: 1 gives "1 second", 30 gives "30 seconds", 120 gives "120 seconds", 121 gives "3 minutes", 3600 gives "60 minutes", and 0 or a negative number is treated as 1. Run rules 1 to 11 for `tooManyAttempts` and `resendCooldown` at every sample `waitSeconds`.
15. Exhaustiveness: the switch that maps `AuthError` to a copy key has no `default`, like `RewriteError.userNotice`, so a new `AuthError` case does not compile until someone chooses wording.
16. Distinct reasons get distinct text: `offline`, `timedOut`, `serviceDown`, `invalidEmail`, `codeRejected`, `codeExpiredLocal`, `tooManyAttempts(30)`, `resendCooldown(30)`, `storageFailed` are all different strings.
17. The copy for the three `AuthError` cases that mean "the service could not be used" (`unreachable`, `unavailable`, `invalidResponse`) is the same string (`serviceDown`) and none of the messages contains the word `reach` (nothing here claims the service was unreachable).

## 8. Check against the existing lint

I parsed the 51 strings in this file and ran them through the rules of `RewriteNoticeTests.swift` (the `banned` list as substrings, no `!`, `sentenceCount` 1 to 2 for messages, at most 120 characters) re-implemented in a script (scratch: `d4d/lint.py`, not committed), plus rules 1 to 11 above, with `waitSeconds` in 1, 2, 30, 60, 120, 121 and 3600. Result: no violations. Longest message rendered with the sample email: 93 characters. The rule from that test file that does not carry over is `testNoticesSayWhatHappenedToTheText` ("raw transcript was inserted"): it is specific to rewrite failures and does not apply to sign-in. The one string that touches the same topic, `signOutSignedOutNotice`, states its own consequence instead ("Dictation still works").
