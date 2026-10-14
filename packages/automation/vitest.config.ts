import { configDefaults, defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    exclude: [...configDefaults.exclude, "src/**/*.chrome.test.ts"],
    maxWorkers: 4,
    testTimeout: 30_000,
    hookTimeout: 30_000,
    coverage: {
      all: true,
      include: ["src/**/*.ts"],
      exclude: [
        "**/dist/**",
        "**/*.test.ts",
        "src/browser-cdp-test-support.ts",
        "src/browser-runtime-lifecycle.ts",
        "src/browser-runtime-factory.ts",
        "src/browser-content.ts",
        "src/browser-frame.ts",
        "src/browser-load-state.ts",
        "src/browser-repl.ts",
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
        "src/browser-use-invoke-mouse.ts",
        "src/browser-use-invoke-navigation.ts",
        "src/browser-use-invoke-page.ts",
        "src/browser-use-invoke-playwright.ts",
        "src/browser-use-invoke.ts",
        "src/browser-use-provider.ts",
        "src/code-executor-source.ts",
        "src/code-executor.ts",
        "src/computer-use-provider.ts",
        "src/computer-use-repl-source.ts"
      ],
      provider: "v8",
      thresholds: { branches: 100, functions: 100, lines: 100, statements: 100 }
    }
  }
})
