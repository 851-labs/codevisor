import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const dialogPage = `<title>Dialogs</title><p id="out">none</p>
  <button onclick="document.querySelector('#out').textContent = 'answer:' + prompt('Your name?', 'Ada')">Ask</button>
  <button onclick="alert('Saved'); document.querySelector('#out').textContent = 'alerted'">Tell</button>`

const it = chromeBrowserSuite("dialogs", ({ crossOrigin }) => ({
  "/dialogs": dialogPage,
  "/framed": `<title>Framed</title><iframe id="cross" src="${crossOrigin}/dialogs"></iframe>`
}))

describe("JavaScript dialogs", () => {
  it("reads a dialog's text and a prompt's default answer before answering", async ({
    browser
  }) => {
    await browser.open("/dialogs")
    const seen = await browser.cell(`
      const page = tab.playwright
      await page.getByRole('button', {name:'Ask'}).click()
      const prompt = await tab.getJsDialog()
      await prompt.accept(prompt.defaultValue + ' Lovelace')
      await page.getByRole('button', {name:'Tell'}).click()
      const alert = await tab.getJsDialog()
      await alert.accept()
      browser.write({
        prompt: [prompt.type, prompt.message, prompt.defaultValue],
        alert: [alert.type, alert.message, alert.defaultValue],
        out: await page.locator('#out').textContent()
      })`)
    expect(seen).toEqual({
      prompt: ["prompt", "Your name?", "Ada"],
      alert: ["alert", "Saved", ""],
      out: "alerted"
    })
  })

  it("returns from a click that opens an alert inside a cross-origin frame", async ({
    browser
  }) => {
    await browser.open("/framed")
    const seen = await browser.cell(`
      const frame = tab.playwright.frameLocator('#cross')
      await frame.getByRole('button', {name:'Tell'}).click({timeoutMs: 5000})
      const alert = await tab.getJsDialog()
      await alert.accept()
      browser.write([alert.type, alert.message, await frame.locator('#out').textContent(), await tab.getJsDialog() ?? null])`)
    expect(seen).toEqual(["alert", "Saved", "alerted", null])
  })
})
