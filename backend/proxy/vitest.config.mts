import { readFileSync } from "node:fs";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// The value the example env file publishes; a test asserts src/hostGuard.ts agrees.
function exampleJwtSecret(): string {
  const text = readFileSync(new URL("./.dev.vars.example", import.meta.url), "utf8");
  const match = /^SUPABASE_JWT_SECRET=(.+)$/m.exec(text);
  if (!match) throw new Error("SUPABASE_JWT_SECRET missing from .dev.vars.example");
  return match[1].trim();
}

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        // Fixed, fake values so a run never depends on a developer's .dev.vars.
        // The KEY-like strings are canaries: the logging tests assert they never appear in logs.
        bindings: {
          SUPABASE_URL: "https://test-project.supabase.test",
          // Pinned so a developer's .dev.vars cannot switch the suite to another verification mode.
          JWT_VERIFY_MODE: "hs256",
          // Not "local-dev-" and >= 32 chars, so it passes the deployed-host guard like a real secret.
          SUPABASE_JWT_SECRET: "test-jwt-secret-CANARY-0123456789abcdef0123456789",
          SUPABASE_SERVICE_ROLE_KEY: "test-service-role-CANARY-7f3a9c",
          ANTHROPIC_API_KEY: "sk-ant-test-CANARY-51d2e8",
          STRIPE_SECRET_KEY: "sk_test_CANARY_a1b2c3",
          STRIPE_WEBHOOK_SECRET: "whsec_CANARY_a1b2c3",
          STRIPE_PRICE_ID: "price_test_CANARY_9f1e2d",
          // Pinned empty (falsy) so a developer's .dev.vars can never redirect test-suite Stripe
          // calls to their local mock-stripe.mjs — stripeClient.ts only honors this when truthy.
          STRIPE_API_BASE_URL: "",
          TEST_EXAMPLE_JWT_SECRET: exampleJwtSecret(),
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
    testTimeout: 30_000,
    // The Worker prints one JSON log line per request; the logging tests capture
    // those with spies, so keep them out of the test report.
    // jose's remote key set rejects an inner promise that its async wrapper adopts a tick later
    // (`async (h, t) => inner(h, t)`). The workers test pool reports that as "Unhandled Rejection"
    // although auth.ts awaits and handles it (the test still asserts the 401). Ignore ONLY these two
    // key-selection codes; any other unhandled error still fails the run.
    onUnhandledError: (error) => {
      const code = (error as { code?: string }).code;
      if (code === "ERR_JWKS_NO_MATCHING_KEY" || code === "ERR_JWKS_MULTIPLE_MATCHING_KEYS") return false;
    },
    onConsoleLog: (log) => (log.startsWith('{"event":"rewrite"') || log.startsWith('{"event":"edit"') ? false : undefined),
  },
});
