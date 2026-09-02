import { defineConfig } from "vitest/config"

// The auth modules orchestrate external CLIs, browser/device flows,
// terminals, and credential files; the lifecycle modules orchestrate
// installers, updaters, terminals, timers, and update feeds; the OpenCode
// server module drives a real `opencode serve` process (rationale carried
// over from the repo root config when these lived in apps/server). Their
// focused tests still run; custom-harnesses and credential-ferry stay at
// 100%. The *-test-support module is shared test
// scaffolding, not product code.
export default defineConfig({
  test: {
    // These tests spawn fake harness CLIs and auth servers per test; on a loaded CI runner — where every
    // package's suite runs in parallel — they need well past vitest's 5s default.
    testTimeout: 30_000,
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/harness-auth.ts",
        "src/harness-auth-accounts.ts",
        "src/harness-auth-core.ts",
        "src/harness-auth-decoration.ts",
        "src/harness-auth-logins.ts",
        "src/harness-auth-probes.ts",
        "src/harness-auth-support.ts",
        "src/harness-lifecycle.ts",
        "src/harness-lifecycle-bundled-app.ts",
        "src/harness-lifecycle-core.ts",
        "src/harness-lifecycle-detection.ts",
        "src/harness-lifecycle-execution.ts",
        "src/harness-lifecycle-support.ts",
        "src/harness-lifecycle-test-support.ts",
        "src/harness-lifecycle-updates.ts",
        "src/opencode-auth.ts",
        "src/opencode-auth-server.ts",
        "src/pi-auth.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
