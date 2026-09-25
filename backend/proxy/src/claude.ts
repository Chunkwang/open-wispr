import Anthropic from "@anthropic-ai/sdk";
import type { Env } from "./types";

// Cleans up raw dictated speech without changing meaning or adding content.
const REWRITE_SYSTEM_PROMPT =
  "You clean up raw dictated speech into polished written text: fix grammar, punctuation, and capitalization, and remove filler words and false starts, without changing the speaker's meaning or adding new content. Return only the rewritten text, nothing else.";

// MAX_TRANSCRIPT_CHARS (16,000) is roughly 4,000 tokens of English, and the
// rewrite is about as long as the input, so this leaves a valid maximum-size
// dictation room to finish. If the output is still cut off we fail the request
// (below) rather than insert half a dictation as if it were complete.
export const REWRITE_MAX_TOKENS = 4096;

export async function rewriteTranscript(transcript: string, env: Env): Promise<string> {
  const client = new Anthropic({
    apiKey: env.ANTHROPIC_API_KEY,
    // The quota already counted this attempt and the client is waiting, so one bounded
    // attempt only. The SDK defaults (10 minute timeout, 2 retries) would let a single
    // request hold a connection and bill up to three attempts for one quota unit.
    timeout: 90_000,
    maxRetries: 0,
    // Resolve the global at call time (the SDK otherwise captures it at import).
    fetch: (input, init) => globalThis.fetch(input, init),
  });

  const response = await client.messages.create({
    // TODO: claude-opus-5 is this skill's default; for a cheap, latency-sensitive
    // grammar/punctuation cleanup task, claude-haiku-4-5 is worth A/B testing
    // against it once real usage data exists (see TRD Section 13 / Path to v2).
    model: "claude-opus-5",
    max_tokens: REWRITE_MAX_TOKENS,
    system: REWRITE_SYSTEM_PROMPT,
    messages: [{ role: "user", content: transcript }],
  });

  // Only a natural finish is a complete rewrite. max_tokens is a cut-off, and
  // refusal, pause_turn, tool_use or anything unknown is not text we may insert.
  if (response.stop_reason !== "end_turn" && response.stop_reason !== "stop_sequence") {
    throw new Error("Claude API did not finish normally");
  }

  const textBlock = response.content.find(
    (block): block is Anthropic.TextBlock => block.type === "text"
  );
  const rewritten = textBlock?.text.trim();
  if (!rewritten) {
    throw new Error("Claude API returned no text content");
  }
  return rewritten;
}
