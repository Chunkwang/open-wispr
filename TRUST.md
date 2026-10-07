# TRUST.md — Verifiable Privacy and Security Claims

*Every claim in this file is traced to the source code that proves it, and where possible, to a command you can run yourself. If a claim and the code disagree, the code is right and this file needs fixing.*

*Last audited: 2026-10-07.*

---

## 1. Keystroke privacy

**Claim:** The app watches for your configured hotkey and ignores every other key. It never records or stores keystrokes.

| Evidence | Location |
|---|---|
| `handleEvent` checks only `event.keyCode` and `event.modifierFlags`; every non-matching event is discarded at `guard event.keyCode == keyCode` | [`HotkeyManager.swift:58–85`](Sources/OpenWisprLib/HotkeyManager.swift) |
| No call to `event.characters` or `event.charactersIgnoringModifiers` exists | Verify: `grep -n 'characters' Sources/OpenWisprLib/HotkeyManager.swift` → 0 matches |
| The callbacks `onKeyDown` and `onKeyUp` are zero-argument closures — no event data is passed through | [`HotkeyManager.swift:31–32`](Sources/OpenWisprLib/HotkeyManager.swift) |
| The monitor is removed on `stop()` | [`HotkeyManager.swift:51–56`](Sources/OpenWisprLib/HotkeyManager.swift) |

---

## 2. Local-first dictation

**Claim:** Dictation works entirely on your Mac with no network connection. Audio is processed on-device by Whisper and is never sent anywhere.

| Evidence | Location |
|---|---|
| `Transcriber` calls the local `whisper-cli` binary — no network call | [`Transcriber.swift`](Sources/OpenWisprLib/Transcriber.swift) |
| Audio files are deleted after transcription (`defer { try? FileManager.default.removeItem }`) | [`AppDelegate.swift:445`](Sources/OpenWisprLib/AppDelegate.swift) |
| Verify: turn off Wi-Fi, dictate. Text appears. | Manual test |

---

## 3. What leaves the device (and what does not)

**Claim:** The only data that leaves your Mac is what you have explicitly consented to, through a disclosure sheet you must accept first.

### 3a. Network egress inventory

Every outbound connection the client makes, with the file that makes it:

| # | Connection | Destination | What is sent | When | File |
|---|---|---|---|---|---|
| 1 | **Whisper model download** | Hugging Face CDN | Nothing (GET request) | First launch, or model change | [`ModelDownloader.swift`](Sources/OpenWisprLib/ModelDownloader.swift) |
| 2 | **Supabase sign-in** | Your Supabase project | Email address + OTP code | When you sign in | [`AuthService.swift`](Sources/OpenWisprLib/AuthService.swift) |
| 3 | **Supabase token refresh** | Your Supabase project | Refresh token | When access token nears expiry | [`AuthService.swift`](Sources/OpenWisprLib/AuthService.swift) |
| 4 | **`POST /v1/rewrite`** | Our Cloudflare Worker proxy | Transcript text only | After dictation, if Rewrite is on + consented + signed in | [`RewritePipeline.swift`](Sources/OpenWisprLib/RewritePipeline.swift) |
| 5 | **`POST /v1/edit`** | Our Cloudflare Worker proxy | Selected text + voice instruction + window title | After Edit hotkey, if consented + signed in | [`EditPipeline.swift`](Sources/OpenWisprLib/EditPipeline.swift) |
| 6 | **`POST /v1/ask`** | Our Cloudflare Worker proxy | Voice question + context text + window title + a screenshot of the frontmost window only, not the full display (if needed) + UI tree | After Ask hotkey, if consented + signed in | [`AskPipeline.swift`](Sources/OpenWisprLib/AskPipeline.swift) |
| 7 | **Sparkle update check** | Appcast URL (not yet deployed) | Nothing (GET request) | Periodic, once wired | [`UpdaterController.swift`](Sources/OpenWisprLib/UpdaterController.swift) |
| 8 | **`GET /v1/me`** | Our Cloudflare Worker proxy | Nothing but the bearer token; response is tier + remaining quota count | On launch, after every sign-in/sign-out, and every few seconds for up to two minutes after "Upgrade to Pro" opens Checkout | [`BillingClient.swift`](Sources/OpenWisprLib/BillingClient.swift), [`TierStore.swift`](Sources/OpenWisprLib/TierStore.swift) |
| 9 | **`POST /v1/billing/checkout`** | Our Cloudflare Worker proxy | Nothing but the bearer token; response is a Stripe-hosted URL, opened in the default browser — no card details ever reach this app | When a signed-in Free user chooses "Upgrade to Pro…" | [`BillingClient.swift`](Sources/OpenWisprLib/BillingClient.swift), [`BillingCoordinator.swift`](Sources/OpenWisprLib/BillingCoordinator.swift) |
| 10 | **`POST /v1/billing/portal`** | Our Cloudflare Worker proxy | Nothing but the bearer token; response is a Stripe-hosted URL, opened in the default browser | When a signed-in Pro user chooses "Manage Subscription…" | [`BillingClient.swift`](Sources/OpenWisprLib/BillingClient.swift), [`BillingCoordinator.swift`](Sources/OpenWisprLib/BillingCoordinator.swift) |

### 3b. What is NEVER sent

| Data | Why not |
|---|---|
| Audio recordings | Processed locally by Whisper, deleted after transcription |
| Keystrokes | `HotkeyManager` reads only key codes (see §1) |
| Clipboard contents | Saved/restored around paste; concealed with `org.nspasteboard.ConcealedType` |
| Screenshots of any window but the one you're asking about | `ScreenCapturer` captures only the frontmost window (`SCContentFilter(desktopIndependentWindow:)`); no other window's or app's pixels are ever rasterized |
| Screenshots of excluded apps | `AskCoordinator` checks the frontmost app against the exclusion list before capturing; `ScreenCapturer` checks again, against the window actually matched, before capturing |
| Anything from password managers, banking apps, crypto wallets | Hard-blocked by `ExcludedApps` and `ScreenCapturer`'s own exclusion check |

---

## 4. Consent gates

**Claim:** No data leaves the device without prior explicit consent through a disclosure sheet.

| Gate | What it protects | Disclosure sheet | File |
|---|---|---|---|
| `RewriteConsent` | Transcript text → proxy | `RewriteDisclosureSheet.swift` | [`RewriteGate.swift`](Sources/OpenWisprLib/RewriteGate.swift) |
| `ContextConsent` (text) | Selected text + window title → proxy | `ContextConsentSheet.swift` | [`ContextConsent.swift`](Sources/OpenWisprLib/ContextConsent.swift) |
| `ContextConsent` (image) | Screenshot → proxy | `ContextConsentSheet.swift` | [`ContextConsent.swift`](Sources/OpenWisprLib/ContextConsent.swift) |

Each consent record stores the version of the disclosure text. Bumping the version invalidates old consent automatically.

---

## 5. Excluded apps (sensitive content protection)

**Claim:** Password managers, banking apps, crypto wallets, healthcare apps, and system security dialogs are automatically blocked from screen capture and context reading.

| Evidence | Location |
|---|---|
| Hardcoded blocklist of ~50 bundle IDs and ~30 prefix patterns | [`ExcludedApps.swift`](Sources/OpenWisprLib/ExcludedApps.swift) |
| `AskCoordinator` and `EditCoordinator` abort before any network call if the frontmost app is excluded | [`AskCoordinator.swift:148,155`](Sources/OpenWisprLib/AskCoordinator.swift), [`EditCoordinator.swift:109,135`](Sources/OpenWisprLib/EditCoordinator.swift) |
| `ScreenCapturer` captures only the frontmost window (`SCContentFilter(desktopIndependentWindow:)`), so no other app's pixels ever enter memory, and refuses to capture that window at all if its own app is on the exclusion list | [`ScreenCapturer.swift`](Sources/OpenWisprLib/ScreenCapturer.swift) |
| Secure text fields (password fields) are detected by AX role and excluded at the `ContextSnapshot` level | [`ContextSnapshot.swift:37,144–158`](Sources/OpenWisprLib/ContextSnapshot.swift) |
| Secure keyboard input (e.g. a Terminal `sudo` prompt or system password dialog) is a separate, system-wide check — not just an AX-detectable field — and blocks Ask, Edit, *and* plain dictation's paste from ever reaching the network or the secure context | [`AccessibilityContextReader.swift`](Sources/OpenWisprLib/AccessibilityContextReader.swift) (`captureSecureInputStatus`/`SecureInputCheck`); call sites: [`AppDelegate.swift:618`](Sources/OpenWisprLib/AppDelegate.swift) (dictation), [`AskCoordinator.swift:143`](Sources/OpenWisprLib/AskCoordinator.swift), [`EditCoordinator.swift:130`](Sources/OpenWisprLib/EditCoordinator.swift) |

---

## 6. Clipboard privacy

**Claim:** Dictated text placed on the pasteboard is marked as concealed and local-only, so clipboard managers don't record it and Universal Clipboard doesn't sync it.

| Evidence | Location |
|---|---|
| `org.nspasteboard.ConcealedType` marker set on every paste | [`TextInserter.swift:70–72`](Sources/OpenWisprLib/TextInserter.swift) |
| `com.apple.pasteboard.local-only` prevents Universal Clipboard sync | [`TextInserter.swift:76–78`](Sources/OpenWisprLib/TextInserter.swift) |
| Original clipboard contents are saved before and restored after each insertion | [`TextInserter.swift:81–98`](Sources/OpenWisprLib/TextInserter.swift) |

---

## 7. Prompt-injection protection

**Claim:** Screen text that attempts to hijack the AI model is detected and dropped locally before leaving the device.

| Evidence | Location |
|---|---|
| `InjectionDetector` scans OCR text for known injection phrases | [`InjectionDetector.swift`](Sources/OpenWisprLib/InjectionDetector.swift) |
| `AskCoordinator` drops the request if injection is detected, in selected text, the window title, or OCR'd screen text | [`AskCoordinator.swift:164,168,225`](Sources/OpenWisprLib/AskCoordinator.swift) |

---

## 8. Server-side guarantees

**Claim:** Our proxy server does not log, store, or retain any user content.

| Evidence | Location |
|---|---|
| Content-free request logging (event, status, latency, SHA-256-truncated user hash only) | [`backend/proxy/src/index.ts:326–334`](backend/proxy/src/index.ts) (`logRequest`) |
| No-content-in-logs test | [`backend/proxy/test/`](backend/proxy/test/) |
| Rate limiting uses Durable Objects with counters only, never content | [`backend/proxy/src/quotaCounter.ts`](backend/proxy/src/quotaCounter.ts), [`backend/proxy/src/rateLimit.ts`](backend/proxy/src/rateLimit.ts) |

---

## How to verify these claims yourself

```bash
# 1. Confirm HotkeyManager never reads keystroke characters
grep -n 'characters' Sources/OpenWisprLib/HotkeyManager.swift
# Expected: 0 matches

# 2. Confirm no network call exists in Transcriber
grep -n 'URLSession\|URLRequest\|URL(string' Sources/OpenWisprLib/Transcriber.swift
# Expected: 0 matches

# 3. Confirm clipboard concealment markers exist
grep -n 'ConcealedType\|local-only' Sources/OpenWisprLib/TextInserter.swift
# Expected: 2+ matches

# 4. Confirm excluded apps list exists
grep -c 'com\.' Sources/OpenWisprLib/ExcludedApps.swift
# Expected: 50+ matches

# 5. Confirm consent gates exist before network calls
grep -n 'hasConsent\|hasTextConsent\|hasImageConsent' Sources/OpenWisprLib/RewriteGate.swift Sources/OpenWisprLib/ContextConsent.swift
# Expected: matches in both files
```
