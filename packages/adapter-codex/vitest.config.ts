import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts", "src/test-support.ts"],
      provider: "v8",
      thresholds: { branches: 69, functions: 92, lines: 91, statements: 87 }
    }
  }
})
