import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts", "src/test-support.ts"],
      provider: "v8",
      thresholds: { branches: 70, functions: 90, lines: 86, statements: 83 }
    }
  }
})
