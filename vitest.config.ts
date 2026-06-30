import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["packages/*/src/**/*.ts", "apps/server/src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts", "apps/server/src/main.ts"],
      provider: "v8",
      thresholds: {
        branches: 100,
        functions: 100,
        lines: 100,
        statements: 100
      }
    }
  }
})
