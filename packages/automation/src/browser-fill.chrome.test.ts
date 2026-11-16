import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const formPage = `<title>Form</title>
  <input id="moment" type="datetime-local"><input id="day" type="date"><input id="clock" type="time">
  <input id="short" maxlength="5"><textarea id="note" maxlength="4"></textarea>
  <input id="digits" oninput="this.value = this.value.replace(/\\D/g, '')">`

const it = chromeBrowserSuite("fill", () => ({ "/form": formPage }))

const fill = (selector: string, text: string) =>
  `await tab.playwright.locator(${JSON.stringify(selector)}).fill(${JSON.stringify(text)}).then(() => tab.playwright.locator(${JSON.stringify(selector)}).evaluate(e => e.value), error => error.message)`

describe("fill", () => {
  it("fills date and time inputs with their own value formats", async ({ browser }) => {
    await browser.open("/form")
    expect(
      await browser.cell(
        `browser.write([${fill("#moment", "2026-12-25T13:45")}, ${fill("#day", "2026-12-25")}, ${fill("#clock", "13:45")}, ${fill("#day", "25/12/2026")}, await tab.playwright.locator('#day').evaluate(e => e.value)])`
      )
    ).toEqual([
      "2026-12-25T13:45",
      "2026-12-25",
      "13:45",
      "Malformed value for input[type=date]",
      "2026-12-25"
    ])
  })

  it("accepts what a length limit keeps, and still reports a field that rewrites its value", async ({
    browser
  }) => {
    await browser.open("/form")
    expect(
      await browser.cell(
        `browser.write([${fill("#short", "1234567")}, ${fill("#note", "abcdef")}, ${fill("#digits", "a1b2")}])`
      )
    ).toEqual(["12345", "abcd", 'Browser fill verification failed: expected "a1b2", received "12"'])
  })
})
