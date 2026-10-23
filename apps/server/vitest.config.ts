import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    env: { CODEVISOR_COMMAND_PRIORITY: "normal" },
    include: ["src/**/*.test.ts", "test/**/*.test.ts"],
    testTimeout: 30_000,
    hookTimeout: 30_000,
    coverage: {
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/test-support.ts",
        "src/changes-test-support.ts",
        "src/test-support-agents.ts",
        "src/test-support-stubs.ts",
        "src/test-support-net.ts",
        "src/cli/support-test-support.ts",
        "src/routes/harness-auth-test-support.ts",
        "src/infra/shared-accounts-test-support.ts",
        "src/infra/mcp-oauth-test-support.ts",
        "src/routes/session-test-support.ts",
        "src/routes/bot-test-support.ts",
        "src/routes/fleet-test-support.ts",
        "src/routes/gateway-test-support.ts",
        "src/routes/response-test-support.ts",
        "src/routes/project-setup-test-support.ts",
        "src/main.ts",
        "src/serve.ts",
        "src/serve-boot.ts",
        "src/serve-self-updater.ts",
        "src/cli.ts",
        "src/cli/wiring.ts",
        "src/terminal-proxy.ts",
        "src/infra/cloud-bridge.ts",
        "src/infra/cloud-bridge-socket.ts",
        "src/infra/cloud-proxy-handlers.ts",
        "src/infra/cloud-tunnel.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
