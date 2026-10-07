import { defineConfig } from "vitest/config"

// Spawning Pi is exercised against a live binary (tophat and e2e runs); the
// protocol, mapping and session logic run on fakes and stay fully covered.
export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts", "src/test-support.ts"],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
