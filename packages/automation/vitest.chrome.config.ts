import { defineConfig } from "vitest/config"

// The real-Chrome suite: behavior only a real rendering engine can show
// (accessibility trees, document order, trusted input, cross-origin frames,
// real CDP events). Everything else about Browser Use is covered with CDP
// fakes in the main suite, which never starts a browser.
//
// It runs outside `bun run check` and the pre-commit hook — see the
// browser-chrome workflow — because a cold Chromium start is slow and
// variable on shared runners.
export default defineConfig({
  test: {
    include: ["src/**/*.chrome.test.ts"],
    env: { CODEVISOR_BROWSER_HEADLESS: "1" },
    // One Chrome at a time: parallel cold starts are what made these slow.
    fileParallelism: false,
    // Headroom past the managed browser's own 90s startup budget
    // (managedBrowserStartupTimeoutMs), so a slow Chromium reports its own
    // timeout instead of vitest's.
    testTimeout: 120_000,
    hookTimeout: 120_000
  }
})
