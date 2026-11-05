import { availableParallelism } from "node:os"

import { defineTestConfig } from "@codevisor/vitest-config"

export default defineTestConfig({
  test: {
    env: { CODEVISOR_COMMAND_PRIORITY: "normal" },
    setupFiles: ["./src/test-setup.ts"],
    maxWorkers: Math.max(2, Math.floor(availableParallelism() / 4)),
    testTimeout: 30_000,
    coverage: {
      include: ["src/**/*.ts"],
      exclude: ["**/*.test.ts", "src/git-test-support.ts", "src/test-setup.ts"],
      provider: "v8",
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 }
    }
  }
})
