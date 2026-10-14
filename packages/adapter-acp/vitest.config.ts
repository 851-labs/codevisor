import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts", "src/test-support.ts"],
      provider: "v8",
      thresholds: { branches: 74, functions: 89, lines: 91, statements: 88 }
    }
  }
})
