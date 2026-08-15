import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts", "test/**/*.test.ts"],
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        // Process entry points and daemon bootstrap wiring: exercised by the
        // release smoke tests, not unit tests.
        "src/main.ts",
        "src/serve.ts",
        "src/cli.ts",
        "src/bg-wrap.ts",
        "src/terminal-proxy.ts",
        // The cloud bridge is an integration boundary over `ws`, live
        // terminals, and the filesystem. Everything it composes is fully
        // covered elsewhere: connection/channel/crypto logic in
        // packages/cloud-client and packages/cloud-crypto, credential parsing
        // and the login flow in src/cli/cloud-auth.ts, and the hub itself in
        // apps/cloud's workerd integration suite.
        "src/infra/cloud-bridge.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
