import { availableParallelism } from "node:os"

import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    // Git runs at normal priority under test; see `withPriority`.
    env: { CODEVISOR_COMMAND_PRIORITY: "normal" },
    // Each worker launches Git processes alongside other package test suites
    // (turbo runs four at once): a quarter of the machine, at least two.
    maxWorkers: Math.max(2, Math.floor(availableParallelism() / 4)),
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: ["**/*.test.ts", "src/git-test-support.ts"],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
