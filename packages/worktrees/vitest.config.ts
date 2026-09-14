import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    // Each worker launches Git processes alongside other package test suites.
    maxWorkers: 2,
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: ["**/*.test.ts", "src/git-test-support.ts"],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
