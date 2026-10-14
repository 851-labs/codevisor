import { availableParallelism } from "node:os"

import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    env: { CODEVISOR_COMMAND_PRIORITY: "normal" },
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
