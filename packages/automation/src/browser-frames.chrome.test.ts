import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, onTestFinished } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const leaf = `<title>Leaf</title><p id="out">none</p><script>console.log('leaf says ' + location.host)</script>
  <button onclick="document.querySelector('#out').textContent = 'clicked'">Frame action</button>
  <label>Frame name<input id="name"></label>`

const picker = `<title>Picker</title><p id="out">none</p>
  <input type="file" id="file" onchange="document.querySelector('#out').textContent = 'file:' + this.files[0].name">`

const it = chromeBrowserSuite("frames", ({ crossOrigin }) => ({
  "/leaf": leaf,
  "/picker": picker,
  "/uploads": `<title>Uploads</title><iframe id="same" src="/picker"></iframe>
    <iframe id="cross" src="${crossOrigin}/picker"></iframe>`,
  "/frames": `<title>Frames</title><button>Top action</button>
    <iframe id="same" src="/leaf"></iframe>
    <iframe id="cross" src="${crossOrigin}/leaf"></iframe>
    <iframe id="inline" srcdoc="<button onclick=&quot;this.textContent='inline clicked'&quot;>Inline action</button>"></iframe>`,
  "/shadowed": `<title>Shadowed</title><div id="open"></div><div id="closed"></div>
    <script>
      document.querySelector('#open').attachShadow({ mode: 'open' }).innerHTML =
        '<iframe id="in-open" src="${crossOrigin}/leaf"></iframe>'
      document.querySelector('#closed').attachShadow({ mode: 'closed' }).innerHTML =
        '<iframe id="in-closed" src="${crossOrigin}/leaf"></iframe><iframe id="same-in-closed" src="/leaf"></iframe>'
    </script>`,
  "/many": `<title>Many</title>
    <iframe class="card" srcdoc="<p>first card</p>"></iframe>
    <iframe class="card" src="${crossOrigin}/leaf"></iframe>
    <iframe class="card" srcdoc="<p>last card</p><iframe class='inner' srcdoc='<p>inner one</p>'></iframe><iframe class='inner' srcdoc='<p>inner two</p>'></iframe>"></iframe>`
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

  it("picks one of several matching frames with first, nth and last", async ({ browser }) => {
    await browser.open("/many")
    const picked = await browser.cell(`
      const cards = tab.playwright.frameLocator('.card')
      browser.write({
        first: await cards.first().locator('p').textContent(),
        second: await cards.nth(1).getByRole('button', {name:'Frame action'}).count(),
        last: await cards.last().locator('p').textContent(),
        nested: await cards.last().frameLocator('.inner').nth(1).locator('p').textContent(),
        unpicked: await cards.locator('p').count().catch(error => error.message)
      })`)
    expect(picked).toEqual({
      first: "first card",
      second: 1,
      last: "last card",
      nested: "inner two",
      unpicked:
        'frameLocator(".card") resolved to 3 frames; pick one with .first(), .last() or .nth(index)'
    })
  })

  it("reaches frames that sit inside open and closed shadow roots", async ({ browser }) => {
    await browser.open("/shadowed")
    const reached = await browser.cell(`
      const page = tab.playwright
      const act = async (selector) => {
        const frame = page.frameLocator(selector)
        await frame.getByRole('button', {name:'Frame action'}).click()
        return frame.locator('#out').textContent()
      }
      browser.write([await act('#in-open'), await act('#in-closed'), await act('#same-in-closed')])`)
    expect(reached).toEqual(["clicked", "clicked", "clicked"])
  })

  it("reads console output from cross-origin frames along with the page's", async ({ browser }) => {
    await browser.open("/frames")
    const hosts = await browser.cell(`
      await tab.playwright.frameLocator('#cross').locator('#out').waitFor({state:'visible'})
      const said = (await tab.dev.logs({filter: 'leaf says'})).map(entry => entry.message.replace('leaf says ', ''))
      browser.write([...new Set(said)].sort())`)
    const { origin, crossOrigin } = browser.origins
    expect(hosts).toEqual([new URL(origin).host, new URL(crossOrigin).host].toSorted())
  })

  it("uploads a file through an input inside a cross-origin frame", async ({ browser }) => {
    const directory = mkdtempSync(join(tmpdir(), "frame-upload-"))
    onTestFinished(() => rmSync(directory, { recursive: true, force: true }))
    const file = join(directory, "report.txt")
    writeFileSync(file, "report")
    await browser.open("/uploads")
    const uploaded = await browser.cell(`
      const upload = async (selector) => {
        const frame = tab.playwright.frameLocator(selector)
        const chooser = tab.playwright.waitForEvent('filechooser', {timeoutMs: 5000})
        await frame.locator('#file').click()
        await (await chooser).setFiles([${JSON.stringify(file)}])
        return frame.locator('#out').textContent()
      }
      browser.write([await upload('#cross'), await upload('#same')])`)
    expect(uploaded).toEqual(["file:report.txt", "file:report.txt"])
  })
})
