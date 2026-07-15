import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["packages/*/src/**/*.ts", "apps/server/src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        // Process entry points and daemon bootstrap wiring: exercised by the
        // release smoke tests, not unit tests.
        "apps/server/src/main.ts",
        "apps/server/src/serve.ts",
        "apps/server/src/cli.ts"
      ],
      provider: "v8",
      thresholds: {
        branches: 100,
        functions: 100,
        lines: 100,
        statements: 100
      }
    }
  }
})
