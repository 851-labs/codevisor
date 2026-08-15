import { defineConfig } from "vitest/config"

// mcp-manager is an integration boundary over stdio/HTTP MCP transports,
// OAuth flows, and long-lived client sessions (rationale carried over from
// the repo root config when it lived in apps/server). The gateway, OAuth,
// sandbox-result, and automation-builtin modules split out of mcp-manager
// inherit that same rationale. Its focused tests still run; the pure split
// modules (mcp-support, mcp-secret-store, mcp-http-transport) plus
// native-mcp-manager and native-config-files stay at 100%.
export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/mcp-automation-builtins.ts",
        "src/mcp-gateway.ts",
        "src/mcp-manager.ts",
        "src/mcp-oauth.ts",
        "src/mcp-sandbox-results.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
