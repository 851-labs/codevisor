import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      provider: "v8",
      include: ["src/**/*.mjs"],
      thresholds: { branches: 90, functions: 100, lines: 95, statements: 95 }
    }
  }
})
