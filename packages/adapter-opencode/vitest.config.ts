import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      provider: "v8",
      reporter: ["text", "json"],
      thresholds: { branches: 88, functions: 90, lines: 98, statements: 95 }
    }
  }
})
