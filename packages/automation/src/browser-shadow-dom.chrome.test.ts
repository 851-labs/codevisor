import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const shadowPage = `<title>Shadow</title><p id="out">none</p>
  <div id="open"></div><div id="closed"></div><div id="covered"></div>
  <div id="cover" style="position:fixed;left:0;top:200px;width:300px;height:60px"></div>
  <script>
    const log = (text) => { document.querySelector('#out').textContent = text }
    const open = document.querySelector('#open').attachShadow({ mode: 'open' })
    open.innerHTML = '<button id="outer">Open shadow</button><div id="nested"></div>'
    open.querySelector('#outer').onclick = () => log('open')
    const nested = open.querySelector('#nested').attachShadow({ mode: 'open' })
    nested.innerHTML = '<button>Nested shadow</button>'
    nested.querySelector('button').onclick = () => log('nested')
    const closed = document.querySelector('#closed').attachShadow({ mode: 'closed' })
    closed.innerHTML = '<button>Closed shadow</button>'
    closed.querySelector('button').onclick = () => log('closed')
    const covered = document.querySelector('#covered')
    covered.style.cssText = 'position:fixed;left:0;top:200px'
    covered.attachShadow({ mode: 'open' }).innerHTML = '<button>Covered shadow</button>'
  </script>`

const it = chromeBrowserSuite("shadow-dom", () => ({ "/shadow": shadowPage }))

const clickButton = (name: string, options = "") =>
  `await tab.playwright.getByRole('button', {name:${JSON.stringify(name)},exact:true}).click(${options})`

describe("Shadow DOM actions", () => {
  it("clicks buttons in open, nested and closed shadow roots", async ({ browser }) => {
    await browser.open("/shadow")
    const clicked: unknown[] = []
    for (const name of ["Open shadow", "Nested shadow", "Closed shadow"]) {
      await browser.cell(clickButton(name))
      clicked.push(await browser.cell("await tab.playwright.locator('#out').textContent()"))
    }
    expect(clicked).toEqual(["open", "nested", "closed"])
  })

  it("still refuses a shadow button that another element covers", async ({ browser }) => {
    await browser.open("/shadow")
    await expect(browser.cell(clickButton("Covered shadow", "{timeoutMs: 0}"))).rejects.toThrow(
      "obscured at its action point"
    )
  })
})
