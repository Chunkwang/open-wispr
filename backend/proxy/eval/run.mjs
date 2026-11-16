#!/usr/bin/env node
// Rewrite-prompt evaluation runner (Task 2.8/2.9).
//
// Always runs the deterministic mock (src/llmProvider.ts mockRewrite) as an end-to-end
// plumbing smoke check. If ANTHROPIC_API_KEY is set in the environment, ALSO calls the
// real Claude API with the exact system prompt and max_tokens this app ships (imported
// straight from src/claude.ts, not copy-pasted, so this script can't silently drift from
// the real prompt). Absent a key it reports "no key, skipping real comparison" and exits 0
// — this is a report, not a CI gate that requires secrets.
//
// Usage:
//   node eval/run.mjs                       # mock only (no key needed)
//   ANTHROPIC_API_KEY=sk-... node eval/run.mjs [--model=claude-haiku-4-5-20251001] [--ids=a,b,c]
//
// IMPORTANT: mock output is a hardcoded regex (see src/llmProvider.ts) — it is a plumbing
// check only and says NOTHING about real prompt/model quality. Only the real-API path,
// compared against the hand-authored "golden" field, is a quality signal.

import { createRequire } from "node:module";
import Module from "node:module";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const ts = require("typescript");

// --- Minimal on-the-fly TS -> CJS loader -----------------------------------------------
// Exists only so this script can `require()` the REAL src/claude.ts (REWRITE_SYSTEM_PROMPT,
// REWRITE_MAX_TOKENS) and src/llmProvider.ts (mockRewrite) instead of duplicating them here,
// which is exactly the kind of copy that goes stale ("prompt drift with no regression test").
// Single-file transpilation with no type-checking is safe for this codebase because src/**
// already writes `import type` for every type-only import (isolatedModules-clean).
Module._extensions[".ts"] = function loadTs(mod, filename) {
  const source = fs.readFileSync(filename, "utf8");
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2021,
      esModuleInterop: true,
    },
    fileName: filename,
  });
  mod._compile(outputText, filename);
};

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const claude = require(path.join(__dirname, "..", "src", "claude.ts"));
const llmProvider = require(path.join(__dirname, "..", "src", "llmProvider.ts"));

const { REWRITE_SYSTEM_PROMPT, REWRITE_MAX_TOKENS } = claude;
const { mockRewrite } = llmProvider;

if (typeof REWRITE_SYSTEM_PROMPT !== "string" || REWRITE_SYSTEM_PROMPT.length === 0) {
  throw new Error("Could not load REWRITE_SYSTEM_PROMPT from src/claude.ts — is it still exported?");
}

// --- CLI args ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const modelArg = args.find((a) => a.startsWith("--model="));
const model = modelArg ? modelArg.slice("--model=".length) : "claude-opus-5";
const idsArg = args.find((a) => a.startsWith("--ids="));
const wantedIds = idsArg ? new Set(idsArg.slice("--ids=".length).split(",")) : null;

// Anthropic API pricing, USD per million tokens (see claude-api skill, cached 2026-06-24).
// Used only to print an estimate alongside a real run; unknown models print "unknown".
const PRICE_PER_MTOK = {
  "claude-opus-5": { in: 5, out: 25 },
  "claude-opus-5-5": { in: 4, out: 20 },
  "claude-sonnet-5": { in: 2, out: 10 },
  "claude-haiku-4-5-20251001": { in: 1, out: 5 },
};

// --- Load the fixed sample set -----------------------------------------------------------
const { samples } = JSON.parse(fs.readFileSync(path.join(__dirname, "transcripts.json"), "utf8"));
const selected = wantedIds ? samples.filter((s) => wantedIds.has(s.id)) : samples;

// --- Guards (mandate: length ratio, must-preserve / must-not-contain, truncation) --------
function lengthRatioFlag(input, output) {
  if (!output) return null;
  const ratio = output.length / Math.max(1, input.length);
  // Filler removal can shrink output notably; flow restructuring rarely expands it much.
  // Outside this band on a short-ish transcript is worth a human look, not an auto-fail.
  if (ratio < 0.35 || ratio > 1.5) return `length ratio ${ratio.toFixed(2)} out of [0.35, 1.5]`;
  return null;
}

function substringGuards(sample, output) {
  const problems = [];
  if (!output) return problems;
  for (const must of sample.mustPreserve ?? []) {
    if (!output.includes(must)) problems.push(`missing required text: "${must}"`);
  }
  for (const bad of sample.mustNotContain ?? []) {
    if (output.toLowerCase().includes(bad.toLowerCase())) problems.push(`contains disallowed text: "${bad}"`);
  }
  return problems;
}

// Crude dominant-script check: flags an output that looks like it was translated into a
// different writing system than the input (e.g. Latin -> Cyrillic/CJK). Not a full language
// detector — just enough to catch a gross "answered in the wrong language" failure.
function scriptOf(text) {
  const counts = { cjk: 0, cyrillic: 0, arabic: 0, latin: 0 };
  for (const ch of text) {
    const cp = ch.codePointAt(0);
    if (cp >= 0x4e00 && cp <= 0x9fff) counts.cjk++;
    else if (cp >= 0x0400 && cp <= 0x04ff) counts.cyrillic++;
    else if (cp >= 0x0600 && cp <= 0x06ff) counts.arabic++;
    else if ((cp >= 0x41 && cp <= 0x7a) || (cp >= 0xc0 && cp <= 0x24f)) counts.latin++;
  }
  let best = "latin";
  for (const k of Object.keys(counts)) if (counts[k] > counts[best]) best = k;
  return counts[best] === 0 ? "unknown" : best;
}

function scriptMismatchFlag(input, output) {
  if (!output) return null;
  const a = scriptOf(input);
  const b = scriptOf(output);
  if (a !== "unknown" && b !== "unknown" && a !== b) return `dominant script changed (${a} -> ${b})`;
  return null;
}

function guardsFor(sample, output) {
  const problems = [];
  const lr = lengthRatioFlag(sample.input, output);
  if (lr) problems.push(lr);
  problems.push(...substringGuards(sample, output));
  const sm = scriptMismatchFlag(sample.input, output);
  if (sm) problems.push(sm);
  return problems;
}

// Sanity-check the golden outputs themselves against their own mustPreserve/mustNotContain —
// a broken eval sample is worse than a missing one. Hard-fails the run (exit 1) if any fire.
let goldenSanityFailed = false;
for (const sample of samples) {
  const problems = substringGuards(sample, sample.golden);
  if (problems.length > 0) {
    goldenSanityFailed = true;
    console.error(`[eval set bug] ${sample.id}: golden fails its own guards: ${problems.join("; ")}`);
  }
}

// --- Truncate long strings for the report -------------------------------------------------
const clip = (s, n = 160) => (s.length > n ? `${s.slice(0, n)}…` : s);

// --- Run --------------------------------------------------------------------------------
async function main() {
  const hasKey = Boolean(process.env.ANTHROPIC_API_KEY);
  let Anthropic = null;
  let client = null;
  if (hasKey) {
    const sdk = require("@anthropic-ai/sdk");
    Anthropic = sdk.default ?? sdk;
    client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY, timeout: 90_000, maxRetries: 0 });
  }

  console.log(`Rewrite eval — ${selected.length} sample(s), model=${model}`);
  console.log(hasKey ? "Real Claude API: ENABLED (ANTHROPIC_API_KEY set)" : "Real Claude API: SKIPPED — no ANTHROPIC_API_KEY in the environment (mock-only run)");
  console.log("=".repeat(100));

  let totalInTok = 0;
  let totalOutTok = 0;
  let totalLatencyMs = 0;
  let realRan = 0;
  const flaggedIds = [];

  for (const sample of selected) {
    console.log(`\n[${sample.id}] (${sample.category})`);
    console.log(`  input : ${clip(sample.input)}`);
    console.log(`  golden: ${clip(sample.golden)}`);
    console.log(`  note  : ${sample.note}`);

    const mockOut = mockRewrite(sample.input);
    const mockProblems = guardsFor(sample, mockOut);
    console.log(`  mock  : ${clip(mockOut)}${mockProblems.length ? `  [MOCK-ONLY FLAGS: ${mockProblems.join(" | ")}]` : ""}`);

    if (!hasKey) {
      console.log(`  real  : not run (no ANTHROPIC_API_KEY — set one and re-run for a real quality read)`);
      continue;
    }

    const started = performance.now();
    let realOut = null;
    let errorText = null;
    let usage = null;
    let stopReason = null;
    try {
      const response = await client.messages.create({
        model,
        max_tokens: REWRITE_MAX_TOKENS,
        system: REWRITE_SYSTEM_PROMPT,
        messages: [{ role: "user", content: sample.input }],
      });
      stopReason = response.stop_reason;
      usage = response.usage;
      const textBlock = response.content.find((b) => b.type === "text");
      if (stopReason !== "end_turn" && stopReason !== "stop_sequence") {
        errorText = `did not finish normally (stop_reason=${stopReason})`;
      } else if (!textBlock?.text?.trim()) {
        errorText = "no text content in reply";
      } else {
        realOut = textBlock.text.trim();
      }
    } catch (err) {
      errorText = err instanceof Error ? err.message : String(err);
    }
    const latencyMs = performance.now() - started;
    totalLatencyMs += latencyMs;
    realRan++;

    if (errorText) {
      console.log(`  real  : ERROR — ${errorText}  (${latencyMs.toFixed(0)} ms)`);
      flaggedIds.push(sample.id);
      continue;
    }

    const problems = guardsFor(sample, realOut);
    if (problems.length) flaggedIds.push(sample.id);
    const price = PRICE_PER_MTOK[model];
    let costStr = "cost: unknown model pricing";
    if (price && usage) {
      const cost = (usage.input_tokens * price.in + usage.output_tokens * price.out) / 1_000_000;
      costStr = `cost: $${cost.toFixed(5)}`;
    }
    if (usage) {
      totalInTok += usage.input_tokens;
      totalOutTok += usage.output_tokens;
    }
    console.log(`  real  : ${clip(realOut)}`);
    console.log(`  stats : ${latencyMs.toFixed(0)} ms, ${usage ? `${usage.input_tokens} in / ${usage.output_tokens} out tok` : "usage unknown"}, ${costStr}`);
    if (problems.length) console.log(`  FLAGS : ${problems.join(" | ")}`);
  }

  console.log(`\n${"=".repeat(100)}`);
  console.log(`Samples: ${selected.length}. Real API calls made: ${realRan}.`);
  if (realRan > 0) {
    const price = PRICE_PER_MTOK[model];
    const totalCost = price ? (totalInTok * price.in + totalOutTok * price.out) / 1_000_000 : null;
    console.log(
      `Real path totals — avg latency: ${(totalLatencyMs / realRan).toFixed(0)} ms/call, tokens: ${totalInTok} in / ${totalOutTok} out` +
        (totalCost !== null ? `, total cost: $${totalCost.toFixed(5)} (${model})` : ", cost: unknown model pricing")
    );
    if (flaggedIds.length) {
      console.log(`Flagged samples (guard failures, review by hand): ${flaggedIds.join(", ")}`);
    } else {
      console.log("No guard failures on the real path.");
    }
  } else {
    console.log("No real numbers in this run — mock output above is a plumbing check only, not a quality signal.");
  }

  if (goldenSanityFailed) {
    console.error("\nEval set has golden outputs that fail their own guards — fix eval/transcripts.json.");
    process.exitCode = 1;
  }
}

await main();
