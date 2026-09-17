import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    // scripts/ runs under `node --test` / `bun test`, not vitest. Vitest's default
    // include would otherwise match scripts/*.test.ts if it were ever run bare at
    // the repo root, picking up suites that spawn real subprocesses.
    exclude: ["**/node_modules/**", "**/dist/**", "scripts/**"],
    coverage: {
      all: true,
      include: ["packages/*/src/**/*.ts"],
      exclude: ["**/dist/**", "**/*.test.ts"],
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
