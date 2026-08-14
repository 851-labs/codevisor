import { defineConfig } from "vitest/config"

// Browser/Computer Use and code execution are integration boundaries over
// Chrome CDP, WebSockets, QuickJS, and native desktop bridges (rationale
// carried over from the repo root config when these lived in apps/server).
// Focused tests still run for every adapter and gateway; the pure tool
// surfaces (automation-provider, codevisor-provider, server-resources) stay
// at 100%.
export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/browser-cdp.ts",
        "src/browser-extension-relay.ts",
        "src/browser-setup-broker.ts",
        "src/browser-use-provider.ts",
        "src/code-executor.ts",
        "src/computer-use-provider.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
