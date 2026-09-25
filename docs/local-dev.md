# Running the rewrite path locally, with no accounts

This runs the whole Day 2 path on one Mac: hold the key, speak, the transcript goes to a local proxy with a mock LLM, and cleaned text lands at the cursor. No Supabase, Stripe or Anthropic account is involved, and no real key or token is used.

**Read the caveats first.**

- This touches your real `~/.config/open-wispr/config.json` (the app reads and writes it; the Rewrite toggle sets `"rewriteMode": "auto"` in it).
- It writes to your real login Keychain (item service `<bundle id>.auth`, account `session-token`). The dev token is a locally minted JWT, but it sits in the same slot a real session token will use.
- The rewrite-consent record is stored in your real `UserDefaults` for the app, under `rewriteDisclosureVersionAccepted`.
- Everything below the "dev" menu items exists only in DEBUG builds. A release build has no Rewrite menu at all until the disclosure sheet (Task 5.1) exists.
- To undo everything: use "Clear dev session token" and "Revoke rewrite consent (dev)" in the menu, then set `rewriteMode` back to `off` (or delete the key) in `config.json`.

## What the app still needs, even for this

The app is not self-contained yet (Tasks 8.2 and 8.3), so before dictation works at all you need:

1. Homebrew `whisper-cpp` (`brew install whisper-cpp`), which provides `whisper-cli`.
2. A downloaded Whisper model: after step 2's build, run `.build/debug/open-wispr download-model base.en` (about 148 MB from Hugging Face; `base.en` is the default in `config.json`). The app would otherwise download it on first start, which is also a network download.
3. Microphone and Accessibility permission for whatever launches the app. If you run the binary from VS Code's terminal, macOS asks you to allow **Visual Studio Code**; from Terminal.app, allow **Terminal**. The first start prompts for both.

Homebrew itself is installed with the one-line installer from brew.sh. Its "Next steps" lines put it on your PATH; the app does not need that (it looks for `whisper-cli` in `/opt/homebrew/bin`), but you need it to run `brew` yourself.

*Verified live on 2026-09-24: with these steps, dictating "um so like send it tomorrow" pasted "Send it tomorrow." on a real Mac (Xcode 27, macOS 26).*

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
OPENWISPR_PROXY_URL=http://127.0.0.1:8787 .build/debug/open-wispr start
```

Notes:

- `OPENWISPR_PROXY_URL` is honoured **only** in DEBUG builds, and only for `https://` or plain `http://` to `127.0.0.1`, `localhost` or `::1`. Anything else is ignored and the request goes to the unresolvable `proxy.invalid`, so it fails safely.
- If a `Dictation-WIP.app` exists in `~/Applications` or `/Applications` (or `OPEN_WISPR_APP` is set), `open-wispr start` relaunches through that bundle, and the environment variable does not reach it. Run with no installed copy, or make sure the one you launch is the DEBUG build.
- Leave the terminal open: it is the app's process.

### 3. Give the app a session token

1. In the proxy terminal: `npm run -s dev:token | pbcopy` (prints only the token; it expires after one hour, so repeat when you see "You're signed out").
2. Click the menu bar icon and choose **Paste dev session token from clipboard**.

**Clear dev session token** removes it again. The token is never printed or logged by the app.

### 4. Record consent (dev only)

Choose **Grant rewrite consent (dev)**. The item then reads "Revoke rewrite consent (dev)". This stands in for the disclosure sheet and exists only in DEBUG builds.

### 5. Turn Rewrite on

Click **Rewrite** so it has a checkmark. The line under it reads **Rewrite: on** when mode, consent and token are all present. Otherwise it says why: "Rewrite: needs sign-in" (no token) or "Rewrite: needs your consent".

### 6. Dictate

Focus a text field (TextEdit is fine), hold the hotkey, say "um so like send it tomorrow", release. The menu bar icon animates while it says "Rewriting...", then `Send it tomorrow.` is pasted.

## What to expect when something is wrong

In every case below the dictation is never lost: the raw transcript is inserted (or, if you switched apps, put on the clipboard) and "Copy Last Dictation" returns the raw text. A notice shows as the warning icon and as the status line of the menu bar menu for about five seconds.

| Scenario | How to make it happen | What you see |
|---|---|---|
| Proxy stopped | Stop `npm run dev` | Raw text inserted. "Couldn't reach the rewrite service. Your raw transcript was inserted instead — nothing was lost." |
| Offline | Turn Wi-Fi off and unplug Ethernet. The app skips the request when macOS reports no network path, even though the local proxy would have answered | "You're offline, and rewrite needs a connection…" and no request is sent |
| Free tier (402) | Restart the mock with `MOCK_TIER=free npm run dev:mock` | "Rewrite is part of Pro…". Rewrites then stop for the rest of the session with no notice repeated |
| Signed out (401) | Use "Clear dev session token" and re-paste an expired or garbled token, or wait an hour. Note: the Worker also checks the token's issuer, so a token minted before Day 3 (no `iss`) is refused: re-mint with `npm run -s dev:token` | "You're signed out. Sign in to keep using rewrite…". Rewrites stop for the session |
| No token at all | "Clear dev session token" | Status line "Rewrite: needs sign-in"; dictation behaves as if rewrite were off |
| Rate limit (429) | More than 5 rewrites in a minute with the same user | "You've reached your rewrite limit…" |
| Very long dictation (413) | Not reproducible with the mock without a very long transcript | "That dictation is too long to rewrite…" |
| Bad reply | Point `OPENWISPR_PROXY_URL` at something that answers 200 with junk | "The rewrite service sent back something unusable…" |
| Switch apps while "Rewriting..." shows | Click another app before the text lands | Nothing is pasted; the text is on your clipboard: "You switched apps before the dictation finished. The text is on your clipboard." |
| Hold the hotkey again while a rewrite is pending | Start a second recording | The earlier text waits until you release the key, then pastes (in order, one at a time) |

After a 401 or 402 the app stops trying for the session so the same text is not sent again. Toggling **Rewrite** off and on (or restarting the app) resets that. Pasting a fresh token alone does not; toggle Rewrite after pasting it.

## Turning it back off

1. **Rewrite** (click to remove the checkmark).
2. **Clear dev session token**.
3. **Revoke rewrite consent (dev)**.
4. Stop `wrangler dev` and the mock (Ctrl-C in each terminal).
