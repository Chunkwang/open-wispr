# Running the rewrite path locally, with no accounts

This runs the whole Day 2 path on one Mac: hold the key, speak, the transcript goes to a local proxy with a mock LLM, and cleaned text lands at the cursor. No Supabase, Stripe or Anthropic account is involved, and no real key or token is used. You sign in with an email code that a local mock issues (step 3).

**Read the caveats first.**

- This touches your real `~/.config/open-wispr/config.json` (the app reads and writes it; the Rewrite toggle sets `"rewriteMode": "auto"` in it).
- It writes to your real login Keychain (item service `<bundle id>.auth`, account `session`). Signing in stores the whole session there (access token, refresh token, expiry, email) as one item. The mock's tokens are locally minted, but they sit in the same slot a real session will use. A DEBUG launch also deletes the old `session-token` item that the earlier paste-a-token shortcut used.
- The rewrite-consent record is stored in your real `UserDefaults` for the app, under `rewriteDisclosureVersionAccepted`.
- Everything below the "dev" menu items exists only in DEBUG builds. A release build has no Rewrite menu at all until the disclosure sheet (Task 5.1) exists.
- To undo everything: use "Sign out" and "Revoke rewrite consent (dev)" in the menu, then set `rewriteMode` back to `off` (or delete the key) in `config.json`.

## What the app still needs, even for this

The app is not self-contained yet (Tasks 8.2 and 8.3), so before dictation works at all you need:

1. Homebrew `whisper-cpp` (`brew install whisper-cpp`), which provides `whisper-cli`.
2. A downloaded Whisper model: after step 2's build, run `.build/debug/open-wispr download-model base.en` (about 148 MB from Hugging Face; `base.en` is the default in `config.json`). The app would otherwise download it on first start, which is also a network download.
3. Microphone and Accessibility permission for whatever launches the app. If you run the binary from VS Code's terminal, macOS asks you to allow **Visual Studio Code**; from Terminal.app, allow **Terminal**. The first start prompts for both.

Homebrew itself is installed with the one-line installer from brew.sh. Its "Next steps" lines put it on your PATH; the app does not need that (it looks for `whisper-cli` in `/opt/homebrew/bin`), but you need it to run `brew` yourself.

*Verified live on 2026-09-24 with the earlier paste-a-token step (the sign-in window in step 3 has been built and unit-tested but not yet run on a real Mac): dictating "um so like send it tomorrow" pasted "Send it tomorrow." on a real Mac (Xcode 27, macOS 26).*

## Steps

### 1. Start the proxy stack (two terminals)

From `backend/proxy/`, following `backend/proxy/README.md` "Local development":

```
npm install                    # once
cp .dev.vars.example .dev.vars # once; edit .dev.vars and uncomment LLM_PROVIDER=mock
```

- Terminal 1: `npm run dev:mock` starts the mock Supabase on `http://127.0.0.1:54321`. It answers `pro` for every user by default; `MOCK_TIER=free npm run dev:mock` makes the proxy answer 402.
- Terminal 2: `npm run dev` starts `wrangler dev`. Its default address is `http://127.0.0.1:8787` (wrangler's default port; the console line "Ready on http://127.0.0.1:8787" confirms it, and it moves to the next free port if 8787 is taken, so read that line).

Sanity check before involving the app:

```
curl -X POST http://127.0.0.1:8787/v1/rewrite \
  -H "Authorization: Bearer $(npm run -s dev:token)" \
  -H "Content-Type: application/json" \
  -d '{"transcript":"um so like send it tomorrow"}'
# {"rewritten":"Send it tomorrow."}
```

### 2. Build and run a DEBUG build

From the repo root (the folder that contains `Package.swift`; in the terminal run `cd "/path/to/new product (voice) idea"` first, keeping the quotes). If `swift build` complains about a missing XCFramework path, the `.build/` folder is stale from before the folder was renamed: delete it (`rm -rf .build`, it is only regenerable build output) and build again.

```
swift build
OPENWISPR_PROXY_URL=http://127.0.0.1:8787 \
OPENWISPR_AUTH_URL=http://127.0.0.1:54321 \
.build/debug/open-wispr start
```

Notes:

- `OPENWISPR_PROXY_URL` is honoured **only** in DEBUG builds, and only for `https://` or plain `http://` to `127.0.0.1`, `localhost` or `::1`. Anything else is ignored and the request goes to the unresolvable `proxy.invalid`, so it fails safely.
- `OPENWISPR_AUTH_URL` (where sign-in requests go) follows the same rules and points at the mock Supabase, `http://127.0.0.1:54321`. Without it, sign-in goes to the unresolvable placeholder `https://auth.invalid`, so sending the code fails with a sign-in service error in the window. `OPENWISPR_AUTH_ANON_KEY` (the public key sent as the `apikey` header) is optional here: the mock accepts any non-empty key and the app's built-in placeholder is used when it is unset. A value that is a `sb_secret_*` key or a service-role JWT is refused and the placeholder is used instead.
- If a `Dictation-WIP.app` exists in `~/Applications` or `/Applications` (or `OPEN_WISPR_APP` is set), `open-wispr start` relaunches through that bundle, and the environment variable does not reach it. Run with no installed copy, or make sure the one you launch is the DEBUG build.
- Leave the terminal open: it is the app's process.

### 3. Sign in

1. Click the menu bar icon and choose **Sign in…**. The sign-in window opens (the app has no Dock icon, so if you click away, **Sign in…** in the menu brings the window back).
2. Enter any email address (the mock accepts any) and press Return or **Send code**.
3. Read the code from the mock's terminal (`mock-supabase: code for <email> is <code>`) or with `curl "http://127.0.0.1:54321/__dev/last-code?email=<email>"`. Type or paste it (digits only; spaces and dashes are dropped) and press Return or **Sign in**.
4. The window says "You're signed in." and the menu now shows a disabled **Signed in as <email>** and **Sign out**. Choose **Done** to close the window.

**Sign out** clears the Keychain item first, then tells the mock. If macOS refuses to delete the item, the app says so and you stay signed in. Nothing about the email, the code or the tokens is printed or logged by the app.

The access token lasts one hour by default (`MOCK_ACCESS_TTL_SECONDS`, default 3600). Refreshing it is Day 5: until then an expired token makes the proxy answer 401 and you see "You're signed out. Sign in to keep using rewrite…". The menu still shows "Signed in as …" in that case; choose **Sign out**, then **Sign in…** again. To see it quickly, start the mock with `MOCK_ACCESS_TTL_SECONDS=60`.

`npm run -s dev:token` still mints a bare token for the `curl` check in step 1; the app does not use it any more.

### 4. Record consent (dev only)

Choose **Grant rewrite consent (dev)**. The item then reads "Revoke rewrite consent (dev)". This stands in for the disclosure sheet and exists only in DEBUG builds.

### 5. Turn Rewrite on

Click **Rewrite** so it has a checkmark. The line under it reads **Rewrite: on** when mode, consent and token are all present. Otherwise it says why: "Rewrite: needs sign-in" (not signed in) or "Rewrite: needs your consent".

### 6. Dictate

Focus a text field (TextEdit is fine), hold the hotkey, say "um so like send it tomorrow", release. The menu bar icon animates while it says "Rewriting...", then `Send it tomorrow.` is pasted.

## What to expect when something is wrong

In every case below the dictation is never lost: the raw transcript is inserted (or, if you switched apps, put on the clipboard) and "Copy Last Dictation" returns the raw text. A notice shows as the warning icon and as the status line of the menu bar menu for about five seconds.

| Scenario | How to make it happen | What you see |
|---|---|---|
| Proxy stopped | Stop `npm run dev` | Raw text inserted. "Couldn't reach the rewrite service. Your raw transcript was inserted instead — nothing was lost." |
| Offline | Turn Wi-Fi off and unplug Ethernet. The app skips the request when macOS reports no network path, even though the local proxy would have answered | "You're offline, and rewrite needs a connection…" and no request is sent |
| Free tier (402) | Restart the mock with `MOCK_TIER=free npm run dev:mock` | "Rewrite is part of Pro…". Rewrites then stop for the rest of the session with no notice repeated |
| Signed out (401) | Start the mock with `MOCK_ACCESS_TTL_SECONDS=60`, sign in, wait a minute, then dictate (refresh is Day 5, so the expired token is sent as it is). Note: the Worker also checks the token's issuer, so the mock's `SUPABASE_URL` must match `.dev.vars` | "You're signed out. Sign in to keep using rewrite…". Rewrites stop for the session |
| Not signed in | "Sign out" | Status line "Rewrite: needs sign-in"; dictation behaves as if rewrite were off |
| Rate limit (429) | More than 5 rewrites in a minute with the same user | "You've reached your rewrite limit…" |
| Very long dictation (413) | Not reproducible with the mock without a very long transcript | "That dictation is too long to rewrite…" |
| Bad reply | Point `OPENWISPR_PROXY_URL` at something that answers 200 with junk | "The rewrite service sent back something unusable…" |
| Switch apps while "Rewriting..." shows | Click another app before the text lands | Nothing is pasted; the text is on your clipboard: "You switched apps before the dictation finished. The text is on your clipboard." |
| Hold the hotkey again while a rewrite is pending | Start a second recording | The earlier text waits until you release the key, then pastes (in order, one at a time) |

After a 401 or 402 the app stops trying for the session so the same text is not sent again. Toggling **Rewrite** off and on (or restarting the app) resets that, and so does signing in or out.

## Turning it back off

1. **Rewrite** (click to remove the checkmark).
2. **Sign out**.
3. **Revoke rewrite consent (dev)**.
4. Stop `wrangler dev` and the mock (Ctrl-C in each terminal).

## Sign-in with the mock

The mock Supabase (`npm run dev:mock` in `backend/proxy`) also implements the email-code sign-in the app uses. There is no real email: the mock prints the code to its own terminal, and you can read it from the dev route.

1. Start the mock on 127.0.0.1:54321 (`SUPABASE_URL` in `.dev.vars` must match, since the Worker checks the token's issuer).
2. In the app choose **Sign in…** (start the app with `OPENWISPR_AUTH_URL`, see step 2), enter any email address, and ask for a code.
3. Read the code from the mock's terminal (`mock-supabase: code for <email> is <code>`) or with `curl "http://127.0.0.1:54321/__dev/last-code?email=<email>"`. Type it into the app.
4. Useful knobs (set them when you start the mock): `MOCK_FIXED_CODE=123456`, `MOCK_OTP_RESEND_SECONDS=5` (default 60), `MOCK_ACCESS_TTL_SECONDS=60` (to watch a refresh happen). Force a failure with `curl -X POST http://127.0.0.1:54321/__dev/fail -H 'content-type: application/json' -d '{"route":"verify","mode":"503","times":1}'`; sign the user out server-side with `/__dev/revoke`; start over with `/__dev/reset`.

The full contract is in `backend/proxy/README.md` ("Mock Supabase").
