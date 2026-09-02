import { defineConfig } from "vitest/config"

// Browser/Computer Use and code execution are integration boundaries over
// Chrome CDP, WebSockets, QuickJS, and native desktop bridges (rationale
// carried over from the repo root config when these lived in apps/server).
// The browser-* modules split out of browser-use-provider — including the
// per-family tool invokers and locator parse/resolve modules — and the code
// executor's source-recovery module inherit that same integration-boundary
// rationale. Focused tests still run for every adapter and gateway; the pure
// tool surfaces (automation-provider, codevisor-provider, server-resources,
// and every tool-definition table) stay at 100%.
export default defineConfig({
  test: {
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/browser-cdp-engine.ts",
        "src/browser-cdp.ts",
        "src/browser-chromium.ts",
        "src/browser-extension-relay.ts",
        "src/browser-input.ts",
        "src/browser-locator-parse.ts",
        "src/browser-locator-resolve.ts",
        "src/browser-locators.ts",
        "src/browser-session-recovery.ts",
        "src/browser-setup-broker.ts",
        "src/browser-snapshot.ts",
        "src/browser-use-invoke-interaction.ts",
        "src/browser-use-invoke-navigation.ts",
        "src/browser-use-invoke-page.ts",
        "src/browser-use-invoke-playwright.ts",
        "src/browser-use-invoke.ts",
        "src/browser-use-provider.ts",
        "src/code-executor-source.ts",
        "src/code-executor.ts",
        "src/computer-use-provider.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
