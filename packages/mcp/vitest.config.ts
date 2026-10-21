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
        "src/mcp-auth-detection.ts",
        "src/mcp-automation-builtins.ts",
        "src/mcp-gateway.ts",
        "src/mcp-gateway-execute.ts",
        "src/mcp-gateway-dispatch.ts",
        "src/mcp-gateway-catalog.ts",
        "src/mcp-manager-browser.ts",
        "src/mcp-manager-core.ts",
        "src/mcp-manager-gateway.ts",
        "src/mcp-manager-replication.ts",
        "src/mcp-manager-servers.ts",
        "src/mcp-manager-test-support.ts",
        "src/mcp-oauth.ts",
        "src/mcp-oauth-provider.ts",
        "src/mcp-oauth-vault-test-support.ts",
        "src/mcp-sandbox-results.ts",
        "src/mcp-upstream.ts",
        "src/native-mcp-test-support.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
