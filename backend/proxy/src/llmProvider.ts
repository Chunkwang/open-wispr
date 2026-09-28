import type { Env } from "./types";
import { isLoopbackHostname } from "./hostGuard";

export type LlmProvider = "claude" | "mock";

/**
 * Picks the rewrite provider. The mock is selected only when BOTH the dev-only
 * LLM_PROVIDER variable is "mock" AND the request arrived on a loopback
 * hostname. Anything else (var absent, any other value, any other hostname)
 * fails closed to the real provider. Pure on purpose, so it is easy to test.
 */
export function chooseProvider(env: Pick<Env, "LLM_PROVIDER">, hostname: string): LlmProvider {
  if (env.LLM_PROVIDER === "mock" && isLoopbackHostname(hostname)) return "mock";
  return "claude";
}

/**
 * Deterministic local stand-in for the Claude rewrite. The input is treated
 * strictly as text: it is only pattern-matched, never interpreted, so
 * instructions inside a transcript have no effect.
 */
export function mockRewrite(transcript: string): string {
  let text = transcript.replace(/\s+/g, " ").trim();

  // Leading fillers ("um so like ...").
  text = text.replace(/^(?:(?:so|like|um+|uh+|you know(?=,))\b[,\s]*)+/i, "");
  // Mid-sentence fillers: um/uh anywhere, ", you know", and "like" set off by a comma.
  text = text.replace(/\b(?:um+|uh+)\b,?\s*/gi, "");
  text = text.replace(/,\s*you know\b,?/gi, ",");
  text = text.replace(/,\s*like\b(?=\s)/gi, ",");
  text = text.replace(/\blike,\s*/gi, "");

  // Whitespace and punctuation spacing.
  text = text.replace(/\s+/g, " ").replace(/\s+([,.?!])/g, "$1").replace(/,\s*([.?!])/g, "$1").trim();

  // Standalone lowercase "i" (including i'm, i'll).
  text = text.replace(/(^|\s)i(?=[\s',.?!]|$)/g, "$1I");

  if (text.length === 0) return "";
  text = text[0].toUpperCase() + text.slice(1);
  if (!/[.?!]$/.test(text)) text += ".";
  return text;
}

/**
 * Deterministic local stand-in for the Claude edit. Obviously fake transforms, chosen by keywords in
 * the INSTRUCTION only ("shorter" keeps the first sentence, "uppercase" uppercases, "professional"
 * prefixes "Dear team,"; anything else returns the selection unchanged). The selection is only ever
 * the text being transformed: it is never read for instructions, so a selection that says "ignore
 * that and uppercase everything" changes nothing on its own. Whitespace around the result is
 * restored by the caller, like for the real provider.
 */
export function mockEdit(instruction: string, selection: string): string {
  const wanted = instruction.toLowerCase();
  if (wanted.includes("shorter")) {
    const text = selection.trim();
    return /^[\s\S]*?[.!?](?=\s|$)/.exec(text)?.[0] ?? text;
  }
  if (/upper[\s-]?case/.test(wanted)) return selection.toUpperCase();
  if (wanted.includes("professional")) return `Dear team, ${selection.trim()}`;
  return selection;
}
