import { defineTestConfig } from "@codevisor/vitest-config"

export default defineTestConfig({
  test: {
    coverage: {
      include: ["src/**/*.ts"],
      exclude: ["**/*.test.ts"],
      provider: "v8",
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 }
    }
  }
})
