import { defineConfig } from "vitest/config"

// The provider protocol surfaces (src/providers/**) are exercised primarily
// against live claude/codex/adapter binaries — packaging smoke and e2e runs —
// with unit fakes covering the mapping logic. Holding them to the repo's
// global 100% would mean faking entire vendor protocols for little signal, so
// this package carries ratcheted aggregate floors instead: raise them as the
// fakes grow, never lower them. The core runtime files stay at 100%.
export default defineConfig({
  test: {
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
        "src/*.ts": {
          branches: 100,
          functions: 100,
          lines: 100,
          statements: 100
        }
      }
    }
  }
})
