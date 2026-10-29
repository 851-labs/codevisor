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
        "src/apple-container-cli.ts",
        "src/apple-container-test-support.ts",
        "src/daytona-sdk.ts",
        "src/e2b-sdk.ts",
        "src/modal-sdk.ts",
        "src/tart-cli.ts",
        "src/tart-orchard-api.ts",
        "src/tart-test-support.ts",
        "src/vercel-sdk.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
