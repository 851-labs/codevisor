import { defineConfig } from "vitest/config"

// The MCP manager is an integration boundary over stdio/HTTP MCP transports,
// OAuth flows, and long-lived client sessions (rationale carried over from
// the repo root config when it lived in apps/server). Its operation modules
// (core registries, upstream connections, auth probing, server/gateway/
// browser/replication operations) inherit that rationale; the composition
// root (mcp-manager.ts), the OAuth flows, the pure split modules
// (mcp-support, mcp-secret-store, mcp-http-transport), and the native-config
// scanner/importer/editor stay at 100%. The *-test-support modules are
// shared test scaffolding, not product code.
export default defineConfig({
  test: {
    // MCP tests stand up real HTTP upstreams, stdio transports, and gateway
    // sessions per test; on a loaded CI runner — where every
    // package's suite runs in parallel — they need well past vitest's 5s default.
    testTimeout: 30_000,
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/mcp-auth-detection.ts",
        "src/mcp-automation-builtins.ts",
        "src/mcp-gateway.ts",
        "src/mcp-gateway-catalog.ts",
        "src/mcp-manager-browser.ts",
        "src/mcp-manager-core.ts",
        "src/mcp-manager-gateway.ts",
        "src/mcp-manager-replication.ts",
        "src/mcp-manager-servers.ts",
        "src/mcp-manager-test-support.ts",
        "src/mcp-oauth.ts",
        "src/mcp-sandbox-results.ts",
        "src/mcp-upstream.ts",
        "src/native-mcp-test-support.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
