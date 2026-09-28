import Anthropic from "@anthropic-ai/sdk";
import type { Env } from "./types";
import { EDIT_MAX_TOKENS, EDIT_SYSTEM_PROMPT, buildEditUserMessage, editOutputCeiling, newDelimiterSuffix, type EditContext } from "./editPrompt";

// Cleans up raw dictated speech without changing meaning or adding content.
const REWRITE_SYSTEM_PROMPT =
  "You clean up raw dictated speech into polished written text: fix grammar, punctuation, and capitalization, and remove filler words and false starts, without changing the speaker's meaning or adding new content. Return only the rewritten text, nothing else.";

// MAX_TRANSCRIPT_CHARS (16,000) is roughly 4,000 tokens of English, and the
// rewrite is about as long as the input, so this leaves a valid maximum-size
// dictation room to finish. If the output is still cut off we fail the request
// (below) rather than insert half a dictation as if it were complete.
export const REWRITE_MAX_TOKENS = 4096;

function makeClient(env: Env): Anthropic {
  return new Anthropic({
    apiKey: env.ANTHROPIC_API_KEY,
    // The quota already counted this attempt and the client is waiting, so one bounded
    // attempt only. The SDK defaults (10 minute timeout, 2 retries) would let a single
    // request hold a connection and bill up to three attempts for one quota unit.
    timeout: 90_000,
    maxRetries: 0,
    // Resolve the global at call time (the SDK otherwise captures it at import).
    fetch: (input, init) => globalThis.fetch(input, init),
  });
}

/** The trimmed text of a finished reply; throws unless it ended naturally with non-empty text. */
function finishedText(response: Anthropic.Message): string {
  // Only a natural finish is a complete reply. max_tokens is a cut-off, and
  // refusal, pause_turn, tool_use or anything unknown is not text we may insert.
  if (response.stop_reason !== "end_turn" && response.stop_reason !== "stop_sequence") {
    throw new Error("Claude API did not finish normally");
  }

  const textBlock = response.content.find(
    (block): block is Anthropic.TextBlock => block.type === "text"
  );
  const text = textBlock?.text.trim();
  if (!text) {
    throw new Error("Claude API returned no text content");
  }
  return text;
}

export async function rewriteTranscript(transcript: string, env: Env): Promise<string> {
  const client = makeClient(env);

  const response = await client.messages.create({
    // TODO: claude-opus-5 is this skill's default; for a cheap, latency-sensitive
    // grammar/punctuation cleanup task, claude-haiku-4-5 is worth A/B testing
    // against it once real usage data exists (see TRD Section 13 / Path to v2).
    model: "claude-opus-5",
    max_tokens: REWRITE_MAX_TOKENS,
    system: REWRITE_SYSTEM_PROMPT,
    messages: [{ role: "user", content: transcript }],
  });

  return finishedText(response);
}

/**
 * Applies a spoken instruction to selected text (`/v1/edit`). Same client discipline as the rewrite:
 * one attempt, 90 s, no retries, and only a natural finish with non-empty text counts. The model is
 * the same as the rewrite's on purpose (measurement is Day 16, task 2.9). A reply far longer than
 * the selection could plausibly need is a runaway and fails like a truncated one.
 */
export async function editSelection(
  instruction: string,
  selection: string,
  context: EditContext | undefined,
  env: Env
): Promise<string> {
  const client = makeClient(env);
  const response = await client.messages.create({
    model: "claude-opus-5",
    max_tokens: EDIT_MAX_TOKENS,
    system: EDIT_SYSTEM_PROMPT,
    messages: [{ role: "user", content: buildEditUserMessage(instruction, selection, context, newDelimiterSuffix()) }],
  });
  const edited = finishedText(response);
  if ([...edited].length > editOutputCeiling(selection)) {
    throw new Error("Claude API reply is implausibly long for this edit");
  }
  return edited;
}
