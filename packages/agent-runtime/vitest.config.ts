import { fileURLToPath } from "node:url"

import { defineConfig } from "vitest/config"

// Ownership model (Wave 2a): package-local suites + thinner runtime keepers.
//
// Adapter packages own their full `test:coverage` runs. This package no longer
// re-includes the full adapter-claude / adapter-codex / adapter-acp suites.
//
// Keepers retained here are only the ACP `runtime-*.test.ts` files that exercise
// agent-runtime through real adapters. Those tests live in adapter-acp to avoid
// a package cycle (adapters depend on agent-runtime). Workspace imports are
// aliased to sources so coverage attributes to this package's files (imports
// normally resolve to dist, which coverage excludes).
//
// Runtime-owned pure helpers (model-selection, attachments, background keys,
// normalizePromptInput, stdio transport edge cases) are covered by local unit
// tests in this package — not by replaying Claude/Codex adapter suites.
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
