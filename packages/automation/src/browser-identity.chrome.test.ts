import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const it = chromeBrowserSuite("identity", () => ({ "/": "<title>Identity</title>" }))

describe("Managed browser identity", () => {
  it("presents itself as an ordinary Chrome, the way the built-in pane does", async ({
    browser
  }) => {
    await browser.open("/")
    expect(
      await browser.cell(
        "await tab.playwright.evaluate(() => ({ webdriver: navigator.webdriver, headless: /Headless/.test(navigator.userAgent) }))"
      )
    ).toEqual({ webdriver: false, headless: false })
  })
})
