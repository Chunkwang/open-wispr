// Shared by mint-dev-token.mjs and mock-supabase.mjs: a minimal .dev.vars reader
// (KEY=VALUE, # comments, optional quotes). Dev tooling only; never used by the Worker.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** backend/proxy/.dev.vars (this file lives in backend/proxy/scripts/lib). */
export const DEV_VARS_FILE = join(dirname(fileURLToPath(import.meta.url)), "..", "..", ".dev.vars");

/** The value of `name` in .dev.vars, or undefined when the file or the key is missing. */
export function readDevVar(name, file = DEV_VARS_FILE) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1 || line.slice(0, eq).trim() !== name) continue;
    let value = line.slice(eq + 1).trim();
    if (value.length >= 2 && /^(["']).*\1$/.test(value)) value = value.slice(1, -1);
    return value;
  }
  return undefined;
}
