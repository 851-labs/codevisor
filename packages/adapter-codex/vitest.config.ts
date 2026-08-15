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
      // test-support.ts is shared test scaffolding (fake app-server client,
      // provider setup) extracted from the old monolithic provider.test.ts,
      // not product code — same exclusion the server package uses.
      exclude: ["**/dist/**", "**/*.test.ts", "src/test-support.ts"],
      provider: "v8",
      thresholds: { branches: 69, functions: 92, lines: 91, statements: 87 }
    }
  }
})
