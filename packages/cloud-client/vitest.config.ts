import { defineConfig } from "vitest/config"

// Product code stays at 100%. machine-connection-test-support.ts is shared
// test scaffolding (fake socket, scripted timers, connection harness)
// extracted from the old monolithic machine-connection.test.ts, not product
// code — same exclusion the server and adapter packages use.
export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts", "src/machine-connection-test-support.ts"],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
