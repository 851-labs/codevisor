import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const leaf = `<title>Leaf</title><p id="out">none</p>
  <button onclick="document.querySelector('#out').textContent = 'clicked'">Frame action</button>
  <label>Frame name<input id="name"></label>`

const it = chromeBrowserSuite("frames", ({ crossOrigin }) => ({
  "/leaf": leaf,
  "/frames": `<title>Frames</title><button>Top action</button>
    <iframe id="same" src="/leaf"></iframe>
    <iframe id="cross" src="${crossOrigin}/leaf"></iframe>
    <iframe id="inline" srcdoc="<button onclick=&quot;this.textContent='inline clicked'&quot;>Inline action</button>"></iframe>`
}))

describe("Frame locators", () => {
  it("finds controls by role inside same-origin, inline and cross-origin frames", async ({
    browser
  }) => {
    await browser.open("/frames")
    const found = await browser.cell(`
      const page = tab.playwright
      const act = async (selector) => {
        const frame = page.frameLocator(selector)
        await frame.getByRole('button', {name:'Frame action'}).click()
        await frame.getByRole('textbox', {name:'Frame name'}).fill(selector)
        return [await frame.locator('#out').textContent(), await frame.locator('#name').evaluate(e => e.value), await frame.getByRole('button').count()]
      }
      const inline = page.frameLocator('#inline')
      await inline.getByRole('button', {name:'Inline action'}).click()
      browser.write({
        same: await act('#same'),
        cross: await act('#cross'),
        inline: await inline.getByRole('button').textContent(),
        topLevelButtons: await page.getByRole('button').count()
      })`)
    expect(found).toEqual({
      same: ["clicked", "#same", 1],
      cross: ["clicked", "#cross", 1],
      inline: "inline clicked",
      topLevelButtons: 1
    })
  })
})
