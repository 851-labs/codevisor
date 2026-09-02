import { defineConfig } from "vitest/config"

// Product code stays at 100%. skills-test-support.ts is shared test
// scaffolding (temp homes, fixture skills, scan lookups) extracted from the
// old monolithic skills-manager.test.ts, not product code — same exclusion
// the server and adapter packages use.
export default defineConfig({
  test: {
    // Skills tests clone real git repositories and shuffle symlinked trees; on a loaded CI runner — where every
    // package's suite runs in parallel — they need well past vitest's 5s default.
    testTimeout: 30_000,
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts", "src/skills-test-support.ts"],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
