import { defineConfig } from "vitest/config"

// The auth managers orchestrate external CLIs, browser/device flows,
// terminals, and credential files; the lifecycle manager orchestrates
// installers, updaters, terminals, timers, and update feeds (rationale
// carried over from the repo root config when these lived in apps/server).
// Their focused tests still run; custom-harnesses stays at 100%.
export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/harness-auth.ts",
        "src/harness-lifecycle.ts",
        "src/opencode-auth.ts",
        "src/pi-auth.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
