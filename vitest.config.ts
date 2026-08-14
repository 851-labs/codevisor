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
        // Same category: the lifecycle manager orchestrates installers,
        // updaters, terminals, timers, and update feeds. Its focused tests
        // (harness-lifecycle.test.ts) cover the state machine and gating;
        // route-level coverage is enforced in server.ts.
        // The cloud bridge is an integration boundary over `ws`, live
        // terminals, and the filesystem. Everything it composes is fully
        // covered elsewhere: connection/channel/crypto logic in
        // packages/cloud-client and packages/cloud-crypto, credential parsing
        // and the login flow in apps/server/src/cli/cloud-auth.ts, and the
        // hub itself in apps/cloud's workerd integration suite.
        "apps/server/src/cloud-bridge.ts"
        // Browser/Computer Use is an integration boundary over Chrome CDP,
        // WebSockets, QuickJS, native desktop bridges, and long-lived MCP
        // sessions. Focused tests still run for every adapter and gateway,
        // while end-to-end automation tests exercise the external runtimes.
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
