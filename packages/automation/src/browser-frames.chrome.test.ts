import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
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

  it("shows frame contents in the snapshot, with refs that act inside the frame", async ({
    browser
  }) => {
    await browser.open("/frames")
    const acted = await browser.cell(`
      const snapshot = await tab.getAXState()
      const refs = [...snapshot.matchAll(/button "Frame action" \\[ref=(e\\d+)\\]/g)].map(match => match[1])
      const input = snapshot.match(/textbox "Frame name" \\[ref=(e\\d+)\\]/)[1]
      for (const ref of refs) await tab.click(ref)
      await tab.fill(input, 'typed by ref')
      const again = await tab.getAXState()
      const inline = again.match(/button "Inline action" \\[ref=(e\\d+)\\]/)[1]
      await tab.playwright.ref(inline).click()
      const page = tab.playwright
      browser.write({
        frameButtons: refs.length,
        nested: /Iframe[^\\n]*\\n\\s+- RootWebArea "Leaf"/.test(snapshot),
        same: await page.frameLocator('#same').locator('#out').textContent(),
        cross: await page.frameLocator('#cross').locator('#out').textContent(),
        filled: await page.frameLocator('#same').locator('#name').evaluate(e => e.value),
        inline: await page.frameLocator('#inline').locator('button').textContent()
      })`)
    expect(acted).toEqual({
      frameButtons: 2,
      nested: true,
      same: "clicked",
      cross: "clicked",
      filled: "typed by ref",
      inline: "inline clicked"
    })
  })

  it("includes each frame's text in the markdown export", async ({ browser }) => {
    await browser.open("/many")
    const path = String(
      await browser.cell("(await tab.content.export({format:'markdown'})).file.path")
    )
    const exported = readFileSync(path, "utf8")
    expect(exported).toContain("# Many")
    for (const text of ["first card", "last card", "inner two", "## Frame: Leaf"])
      expect(exported).toContain(text)
  })

  it("measures and captures an element in a cross-origin frame in the tab's coordinates", async ({
    browser
  }) => {
    await browser.open("/frames")
    const measured = String(
      await browser.cell(`
      const page = tab.playwright
      const button = page.frameLocator('#cross').getByRole('button', {name:'Frame action'})
      const frame = await page.locator('#cross').boundingBox()
      const box = await button.boundingBox()
      const inside = await button.evaluate(element => { const rect = element.getBoundingClientRect(); return [rect.x, rect.y] })
      const shot = await button.screenshot()
      browser.write([box.x - frame.x - inside[0], box.y - frame.y - inside[1], box.width, box.height].map(Math.round).join(',') + '|' + shot.image.data.slice(0, 44))`)
    )
    const [box = "", header = ""] = measured.split("|")
    const [insetX, insetY, width, height] = box.split(",").map(Number)
    const png = Buffer.from(header, "base64")
    expect([insetX, insetY]).toEqual([2, 2])
    expect([png.readUInt32BE(16), png.readUInt32BE(20)]).toEqual([width, height])
  })

  it("keeps raw CDP inside the tab: frames are reachable, other tabs are not", async ({
    browser
  }) => {
    const { origin, crossOrigin } = browser.origins
    await browser.open("/leaf")
    const scoped = await browser.cell(`
      const info = async (owner) => (await (await owner.capabilities.get('cdp')).send('Target.getTargetInfo')).targetInfo
      const elsewhere = await info(tab)
      const framed = await browser.tabs.new()
      await framed.goto(${JSON.stringify(`${origin}/frames`)})
      await framed.playwright.frameLocator('#cross').getByRole('button', {name:'Frame action'}).waitFor()
      const cdp = await framed.capabilities.get('cdp')
      const targets = (await cdp.send('Target.getTargets')).targetInfos
      const frame = targets.find(target => target.type === 'iframe')
      const where = { expression: 'location.pathname + " on " + location.host', returnByValue: true }
      const refused = (run) => run().then(() => false, (error) => /isn't this tab or one of its cross-site frames/.test(error.message))
      browser.write({
        listed: targets.map(target => target.type).sort(),
        inFrame: (await cdp.send('Runtime.evaluate', where, { target: frame.targetId })).result.value,
        inTab: (await cdp.send('Runtime.evaluate', where)).result.value,
        otherTabRefused: await refused(() => cdp.send('Runtime.evaluate', where, { target: elsewhere.targetId })),
        closeOtherRefused: await refused(() => cdp.send('Target.closeTarget', { targetId: elsewhere.targetId })),
        otherStillOpen: (await info(tab)).targetId === elsewhere.targetId
      })`)
    expect(scoped).toEqual({
      listed: ["iframe", "page"],
      inFrame: `/leaf on ${new URL(crossOrigin).host}`,
      inTab: `/frames on ${new URL(origin).host}`,
      otherTabRefused: true,
      closeOtherRefused: true,
      otherStillOpen: true
    })
  })

  it("goes network-idle once a page with a cross-origin frame has loaded", async ({ browser }) => {
    await browser.open("/frames")
    const settled = await browser.cell(`
      await tab.playwright.waitForLoadState({state:'networkidle', timeoutMs: 3000})
      browser.write('idle')`)
    expect(settled).toBe("idle")
  })
})
