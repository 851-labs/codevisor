import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const it = chromeBrowserSuite("viewport", () => ({ "/": "<title>Viewport</title>" }))

const size = (tab: string) => `await ${tab}.playwright.evaluate(() => [innerWidth, innerHeight])`

describe("Viewport", () => {
  it("opens managed tabs at a desktop size", async ({ browser }) => {
    await browser.open("/")
    expect(await browser.cell(size("tab"))).toEqual([1440, 900])
  })

  it("overrides one tab's viewport and leaves other tabs alone", async ({ browser }) => {
    await browser.open("/")
    const sizes = await browser.cell(`
      var other = await browser.tabs.new()
      await other.goto(${JSON.stringify("about:blank")})
      const viewport = await tab.capabilities.get('viewport')
      await viewport.set({ width: 390, height: 844 })
      const overridden = [${size("tab")}, ${size("other")}]
      await viewport.reset()
      browser.write({ overridden, reset: ${size("tab")}, listed: (await tab.capabilities.list()).map(entry => entry.id) })`)
    expect(sizes).toEqual({
      overridden: [
        [390, 844],
        [1440, 900]
      ],
      reset: [1440, 900],
      listed: ["cdp", "pageAssets", "webmcp", "viewport"]
    })
  })
})
