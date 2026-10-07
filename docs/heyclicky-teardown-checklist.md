# HeyClicky hands-on teardown: a one-hour checklist

**Who does it:** the founder, on the free tier (25 talk and 25 agent messages a month is enough). **Goal:** find out what it is *really* like, so our "better" is measured against the real product and not against its website.

**Rules:** do not enter real passwords, banking or client data on screen while testing. Use a throwaway account and a test document. Keep the app's permission prompts visible: screenshots of each are useful. Write what you *observe*, not what you expect.

A phone stopwatch is enough for timings. Fill in the table at the bottom as you go (a copy-paste into the chat is fine; I will turn it into the scorecard).

## Setup (10 minutes)
1. Download from heyclicky.com and install. **Count the permission pop-ups** and note the exact wording of each (microphone, accessibility, screen recording, anything else). Note: did it explain *why* before the system prompt?
2. Note: sign-up required? Email only, or more? Was a card asked for?
3. Find the privacy/settings screen. Is there a way to see what was sent? To delete data? To turn off saving? Screenshot it.
4. Note the idle resource use: open Activity Monitor, find the app, write down memory and CPU while idle for a minute.

## Tests (35 minutes)
For every test write: what you said, what happened, seconds from letting go of the key to the first useful result, and whether it was right.

| # | Test | What to say or do | Look for |
|---|---|---|---|
| 1 | Plain dictation | In TextEdit, dictate a 2-sentence note, with an "um" and a self-correction ("send it Tuesday, no, Wednesday") | Speed, accuracy, does it clean the "um", does it change your meaning |
| 2 | Dictation with the internet off | Turn Wi-Fi off, dictate again | Does anything appear? What message? **Turn Wi-Fi back on afterwards** |
| 3 | "What is this?" | Open a web page (a news article), ask "summarise what I'm looking at" | Accuracy, speed, does it read the screen or the page text |
| 4 | Error explanation | Open a page or app with an error message, ask "what does this error mean?" | Does it get the exact text right |
| 5 | Pointing | In a busy app (System Settings), ask "where do I turn on dark mode?" | Does the pointer land on the right control? How many tries out of 3 |
| 6 | Edit selected text | Select a sentence, say "make this more professional" | Does it work at all, does it replace the text, can you undo with Cmd+Z |
| 7 | Sensitive screen | Open a page with a fake password field, ask "what's on my screen?" | Does it read or mention the password field |
| 8 | Agent (one simple task) | "clicky agent, open Calendar and tell me what day it is" (or similar harmless task) | How does it ask permission, what does the confirmation show (raw details or a friendly summary?), can it be stopped |
| 9 | Interrupt and failure | Start a question, then switch apps mid-answer; ask something impossible | Graceful or confusing |
| 10 | Free-limit behaviour | Look at how it shows your remaining messages | Clear? Annoying? |

## Then (15 minutes): our questions
- Where did it feel **slow**? Where did it feel **magic** (write the exact moment)?
- What did it ask for that you did *not* expect?
- If you had to explain to a friend in one sentence why you would use it every day, what would you say? Would you pay $20 a month? Why or why not?
- What annoyed you enough to stop?

## Optional, 10 minutes: Wispr Flow's free plan, same tests 1, 2 and 6 (dictation, no internet, edit selection)

## Results table (copy this)

| Test | Result (right / wrong / partial) | Seconds | Notes |
|---|---|---|---|
| Setup: number of permission pop-ups | | | |
| Idle memory / CPU | | | |
| 1 Dictation | | | |
| 2 Offline | | | |
| 3 Summarise | | | |
| 4 Error meaning | | | |
| 5 Pointing (x of 3) | | | |
| 6 Edit selection | | | |
| 7 Sensitive screen | | | |
| 8 Agent + confirmation | | | |
| 9 Interrupt | | | |
| 10 Limits display | | | |

## What I will do with it
Turn the table into a scorecard against our four bets (`murmur-implementation-plan.md`, "Product bets"), pick the one or two moments that felt like magic as our must-match, and list the annoyances as our "do not repeat" list.
