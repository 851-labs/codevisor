import { defineTestConfig } from "@codevisor/vitest-config"

export default defineTestConfig({
  test: {
    coverage: {
      provider: "v8",
      reporter: ["text", "json"],
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 }
    }
  }
})
