import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    include: ["src/**/*.chrome.test.ts"],
    env: { CODEVISOR_BROWSER_HEADLESS: "1" },
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 120_000
  }
})
