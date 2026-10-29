import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      provider: "v8",
      include: ["src/**/*.mjs"],
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 }
    }
  }
})
