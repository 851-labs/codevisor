import { defineConfig } from "vitest/config"

// Adapter protocol surfaces are exercised primarily against live harness
// binaries (packaging smoke and e2e runs), with unit fakes covering the
// mapping logic — the same rationale as the pre-extraction providers/**
// floors in @codevisor/agent-runtime. Ratcheted aggregate floors: raise them
// as the fakes grow, never lower them.
export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts"],
      provider: "v8",
      thresholds: { branches: 74, functions: 89, lines: 91, statements: 88 }
    }
  }
})
