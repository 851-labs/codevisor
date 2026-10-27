import { availableParallelism } from "node:os"

import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    maxWorkers: Math.max(2, Math.floor(availableParallelism() / 4)),
    coverage: {
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/e2b-sdk.ts",
        "src/modal-sdk.ts",
        "src/tart-cli.ts",
        "src/tart-test-support.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
