import Anthropic from "@anthropic-ai/sdk";
import type { Env } from "./types";

// Cleans up raw dictated speech without changing meaning or adding content.
const REWRITE_SYSTEM_PROMPT =
  "You clean up raw dictated speech into polished written text: fix grammar, punctuation, and capitalization, and remove filler words and false starts, without changing the speaker's meaning or adding new content. Return only the rewritten text, nothing else.";

export async function rewriteTranscript(transcript: string, env: Env): Promise<string> {
  const client = new Anthropic({ apiKey: env.ANTHROPIC_API_KEY });

  const response = await client.messages.create({
    // TODO: claude-opus-5 is this skill's default; for a cheap, latency-sensitive
    // grammar/punctuation cleanup task, claude-haiku-4-5 is worth A/B testing
    // against it once real usage data exists (see TRD Section 13 / Path to v2).
    model: "claude-opus-5",
    max_tokens: 2048,
    system: REWRITE_SYSTEM_PROMPT,
    messages: [{ role: "user", content: transcript }],
  });

  const textBlock = response.content.find(
    (block): block is Anthropic.TextBlock => block.type === "text"
  );
  if (!textBlock) {
    throw new Error("Claude API returned no text content");
  }
  return textBlock.text.trim();
}
