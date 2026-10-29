import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    testTimeout: 30_000,
    hookTimeout: 30_000,
    coverage: {
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/claude-conversation-storage.ts",
        "src/harness-auth.ts",
        "src/harness-auth-accounts.ts",
        "src/harness-auth-core.ts",
        "src/harness-auth-decoration.ts",
        "src/harness-auth-logins.ts",
        "src/harness-auth-probes.ts",
        "src/harness-auth-support.ts",
        "src/harness-lifecycle.ts",
        "src/harness-lifecycle-bundled-app.ts",
        "src/harness-lifecycle-core.ts",
        "src/harness-lifecycle-detection.ts",
        "src/harness-lifecycle-execution.ts",
        "src/harness-lifecycle-support.ts",
        "src/harness-lifecycle-test-support.ts",
        "src/harness-lifecycle-updates.ts",
        "src/shared-credential-vault-test-support.ts",
        "src/opencode-auth.ts",
        "src/opencode-auth-server.ts",
        "src/pi-auth.ts"
      ],
      provider: "v8",
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 }
    }
  }
})
