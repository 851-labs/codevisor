import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const it = chromeBrowserSuite("snapshot", () => ({
  "/rows": `<title>Rows</title><p id="out">none</p><ul id="rows"></ul>
    <footer><button onclick="document.querySelector('#out').textContent = 'footer'">Footer action</button></footer>
    <script>
      document.querySelector('#rows').innerHTML = Array.from({ length: 900 }, (_, index) =>
        '<li><button onclick="document.querySelector(\\'#out\\').textContent = this.textContent">Buy ' + (index + 1) + '</button></li>'
      ).join('')
    </script>`
}))

describe("Snapshots of long pages", () => {
  it("reads on past the first 2,000 lines with refs that still act", async ({ browser }) => {
    await browser.open("/rows")
    const paged = await browser.cell(`
      const first = await tab.getAXState()
      const note = first.split('\\n').at(-1)
      const next = Number(note.match(/offset: (\\d+)/)[1])
      const second = await tab.getAXState({ offset: next })
      const early = first.match(/button "Buy 2" \\[ref=(e\\d+)\\]/)[1]
      const late = second.match(/button "Buy 890" \\[ref=(e\\d+)\\]/)[1]
      const clicked = []
      for (const ref of [late, early]) {
        await tab.click(ref)
        clicked.push(await tab.playwright.locator('#out').textContent())
      }
      browser.write({
        firstHasLate: first.includes('"Buy 890"'),
        sameSnapshot: first.split('\\n')[1] === second.split('\\n')[1],
        noteStart: note.slice(0, 16),
        clicked
      })`)
    expect(paged).toEqual({
      firstHasLate: false,
      sameSnapshot: true,
      noteStart: "[Lines 1-2000 of",
      clicked: ["Buy 890", "Buy 2"]
    })
  })

  it("captures one part of the page under a locator", async ({ browser }) => {
    await browser.open("/rows")
    const part = await browser.cell(`
      const footer = await tab.getAXState({ root: tab.playwright.locator('footer') })
      await tab.click(footer.match(/button "Footer action" \\[ref=(e\\d+)\\]/)[1])
      browser.write({
        lines: footer.split('\\n').slice(3).map(line => line.replace(/ \\[ref=e\\d+\\]/, '')),
        out: await tab.playwright.locator('#out').textContent()
      })`)
    expect(part).toEqual({
      lines: ["- contentinfo", '  - button "Footer action"'],
      out: "footer"
    })
  })
})
