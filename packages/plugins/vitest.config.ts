import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      // test-support.ts is shared test scaffolding (fake spawners, fixture
      // plugin servers, the manager factory) extracted from the supervisor
      // and manager suites, not product code — same exclusion the server
      // package uses.
      exclude: ["**/dist/**", "**/*.test.ts", "src/test-support.ts"],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
