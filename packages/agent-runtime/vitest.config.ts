import { fileURLToPath } from "node:url"

import { defineConfig } from "vitest/config"

const src = (path: string): string => fileURLToPath(new URL(path, import.meta.url))

export default defineConfig({
  resolve: {
    alias: {
      "@codevisor/agent-runtime": src("./src/index.ts"),
      "@codevisor/adapter-acp": src("../adapter-acp/src/index.ts"),
      "@codevisor/adapter-claude": src("../adapter-claude/src/index.ts"),
      "@codevisor/adapter-codex": src("../adapter-codex/src/index.ts")
    }
  },
  test: {
    include: ["src/**/*.test.ts", "../adapter-acp/src/runtime-*.test.ts"],
    coverage: {
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts"],
      provider: "v8",
      thresholds: {
        branches: 55,
        functions: 80,
        lines: 80,
        statements: 78,
        "src/!(model-selection|stdio-transport).ts": {
          branches: 80,
          functions: 80,
          lines: 80,
          statements: 80
        },
        "src/model-selection.ts": {
          branches: 68,
          functions: 80,
          lines: 80,
          statements: 80
        },
        "src/stdio-transport.ts": {
          branches: 71,
          functions: 76,
          lines: 80,
          statements: 80
        }
      }
    }
  }
})
