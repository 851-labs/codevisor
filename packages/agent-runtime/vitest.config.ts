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
      all: true,
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts"],
      provider: "v8",
      thresholds: {
        branches: 55,
        functions: 84,
        lines: 81,
        statements: 78,
        "src/!(model-selection|stdio-transport).ts": {
          branches: 100,
          functions: 100,
          lines: 100,
          statements: 100
        },
        "src/model-selection.ts": {
          branches: 68,
          functions: 83,
          lines: 95,
          statements: 85
        },
        "src/stdio-transport.ts": {
          branches: 71,
          functions: 76,
          lines: 91,
          statements: 86
        }
      }
    }
  }
})
