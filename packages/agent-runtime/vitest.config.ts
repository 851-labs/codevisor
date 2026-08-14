import { fileURLToPath } from "node:url"
import { defineConfig } from "vitest/config"

// The runtime's integration tests live in @codevisor/adapter-acp
// (runtime-acp.test.ts): they exercise the runtime through real adapters, and
// the adapters depend on this package — the tests can't live here without a
// package cycle. This config runs that suite as part of this package's test
// run, with workspace imports aliased back to sources so coverage attributes
// to this package's files (imports normally resolve to dist, which coverage
// excludes).
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
    include: [
      "src/**/*.test.ts",
      "../adapter-acp/src/*.test.ts",
      "../adapter-claude/src/*.test.ts",
      "../adapter-codex/src/*.test.ts"
    ],
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
        // model-selection and stdio-transport moved here from providers/**
        // during the adapter extraction and keep their ratcheted floors
        // (raise as fakes grow, never lower). Everything else stays at 100%.
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
