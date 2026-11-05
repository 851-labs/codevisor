import { defineTestConfig } from "@codevisor/vitest-config"

export default defineTestConfig({
  test: {
    coverage: {
      provider: "v8",
      include: ["src/**/*.mjs"],
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 }
    }
  }
})
