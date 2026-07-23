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
        "apps/server/src/cli.ts",
        // Authentication managers orchestrate external CLIs, browser/device
        // flows, terminals, and credential files. Their focused integration
        // tests still run, while unit coverage is enforced at their server
        // route and runtime boundaries.
        "apps/server/src/harness-auth.ts",
        "apps/server/src/pi-auth.ts",
        "apps/server/src/opencode-auth.ts",
        // Same category: the lifecycle manager orchestrates installers,
        // updaters, terminals, timers, and update feeds. Its focused tests
        // (harness-lifecycle.test.ts) cover the state machine and gating;
        // route-level coverage is enforced in server.ts.
        "apps/server/src/harness-lifecycle.ts",
        // Browser/Computer Use is an integration boundary over Chrome CDP,
        // WebSockets, QuickJS, native desktop bridges, and long-lived MCP
        // sessions. Focused tests still run for every adapter and gateway,
        // while end-to-end automation tests exercise the external runtimes.
        "apps/server/src/browser-cdp.ts",
        "apps/server/src/browser-extension-relay.ts",
        "apps/server/src/browser-setup-broker.ts",
        "apps/server/src/browser-use-provider.ts",
        "apps/server/src/code-executor.ts",
        "apps/server/src/computer-use-provider.ts",
        "apps/server/src/mcp-manager.ts"
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
