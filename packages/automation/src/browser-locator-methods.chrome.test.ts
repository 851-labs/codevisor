import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, onTestFinished } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const controls = `<title>Controls</title><p id="out">none</p>
  <script>const say = (text) => { document.querySelector('#out').textContent = text }</script>
  <button id="hover" onmouseenter="say('hovered')">Hover me</button>
  <input id="name" value="Ada" onfocus="say('focused')" onblur="say('blurred')">
  <input id="locked" value="fixed" readonly>
  <input id="off" value="off" disabled>
  <label><input type="checkbox" id="agree" checked>Agree</label>
  <div id="switch" role="switch" aria-checked="false">Switch</div>
  <input type="file" id="file" multiple onchange="say([...this.files].map(file => file.name).join(','))">
  <img alt="Company logo" title="Home" width="40" height="20" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==">
  <div id="custom" onclick="say('clicked ' + event.detail)">Custom</div>
  <div id="hidden" style="display:none">Hidden</div>
  <div id="box" style="position:absolute;left:300px;top:400px;width:120px;height:50px;background:#06c">Box</div>
  <div style="height:3000px"></div>
  <button id="far" onclick="say('far')">Far away</button>
  <script>document.querySelector('#custom').addEventListener('ping', (event) => say('ping ' + event.bubbles))</script>`

const dragging = `<title>Dragging</title><p id="out">none</p>
  <div id="card" draggable="true" style="width:80px;height:40px;background:#c60">Card</div>
  <div id="bin" style="margin-top:120px;width:200px;height:100px;background:#ddd">Bin</div>
  <script>
    const bin = document.querySelector('#bin')
    document.querySelector('#card').addEventListener('dragstart', (event) => event.dataTransfer.setData('text/plain', 'card'))
    bin.addEventListener('dragover', (event) => event.preventDefault())
    bin.addEventListener('drop', (event) => { event.preventDefault(); document.querySelector('#out').textContent = 'dropped ' + event.dataTransfer.getData('text/plain') })
  </script>`

const it = chromeBrowserSuite("locator-methods", () => ({
  "/controls": controls,
  "/dragging": dragging
}))

describe("Playwright locator methods", () => {
  it("acts on elements: hover, focus, blur, clear, scroll, events and files", async ({
    browser
  }) => {
    const directory = mkdtempSync(join(tmpdir(), "browser-files-"))
    onTestFinished(() => rmSync(directory, { recursive: true, force: true }))
    const files = ["one.txt", "two.txt"].map((name) => join(directory, name))
    for (const file of files) writeFileSync(file, "text")

    await browser.open("/controls")
    const acted = await browser.cell(`
      const page = tab.playwright
      const out = () => page.locator('#out').textContent()
      const steps = {}
      await page.locator('#hover').hover()
      steps.hover = await out()
      await page.locator('#name').focus()
      steps.focus = await out()
      await page.locator('#name').blur()
      steps.blur = await out()
      await page.locator('#name').clear()
      steps.clear = await page.locator('#name').inputValue()
      await page.locator('#custom').dispatchEvent('click', { detail: 3 })
      steps.click = await out()
      await page.locator('#custom').dispatchEvent('ping')
      steps.custom = await out()
      await page.locator('#file').setInputFiles(${JSON.stringify(files)})
      steps.files = await out()
      await page.locator('#file').setInputFiles([])
      steps.cleared = await page.locator('#file').evaluate(input => input.files.length)
      steps.before = await page.evaluate(() => window.scrollY)
      await page.locator('#far').scrollIntoViewIfNeeded()
      steps.scrolled = await page.evaluate(() => window.scrollY > 1000)
      browser.write(steps)`)
    expect(acted).toEqual({
      hover: "hovered",
      focus: "focused",
      blur: "blurred",
      clear: "",
      click: "clicked 3",
      custom: "ping true",
      files: "one.txt,two.txt",
      cleared: 0,
      before: 0,
      scrolled: true
    })
  })

  it("reads element state the way Playwright does", async ({ browser }) => {
    await browser.open("/controls")
    const state = await browser.cell(`
      const page = tab.playwright
      const failure = (run) => run().then(() => 'no error', (error) => error.message)
      browser.write({
        inputValue: await page.locator('#name').inputValue(),
        inputValueOfDiv: await failure(() => page.locator('#custom').inputValue()),
        checked: [await page.locator('#agree').isChecked(), await page.locator('#switch').isChecked()],
        checkedOfDiv: await failure(() => page.locator('#custom').isChecked()),
        editable: [await page.locator('#name').isEditable(), await page.locator('#locked').isEditable(), await page.locator('#off').isEditable()],
        disabled: [await page.locator('#name').isDisabled(), await page.locator('#off').isDisabled()],
        hidden: [await page.locator('#name').isHidden(), await page.locator('#hidden').isHidden(), await page.locator('#missing').isHidden()],
        html: await page.locator('label').innerHTML(),
        box: await page.locator('#box').boundingBox(),
        hiddenBox: await page.locator('#hidden').boundingBox(),
        byAlt: await page.getByAltText('company logo').getAttribute('title'),
        byTitle: await page.getByTitle('Home', { exact: true }).getAttribute('alt'),
        scopedAlt: await page.locator('body').getByAltText(/logo$/).count()
      })`)
    expect(state).toEqual({
      inputValue: "Ada",
      inputValueOfDiv: expect.stringContaining(
        "inputValue needs an <input>, <textarea> or <select>"
      ),
      checked: [true, false],
      checkedOfDiv: expect.stringContaining("isChecked needs a checkbox or radio button"),
      editable: [true, false, false],
      disabled: [false, true],
      hidden: [false, true, true],
      html: '<input type="checkbox" id="agree" checked="">Agree',
      box: { x: 300, y: 400, width: 120, height: 50 },
      hiddenBox: null,
      byAlt: "Home",
      byTitle: "Company logo",
      scopedAlt: 1
    })
  })

  it("drags one element onto another and captures one element", async ({ browser }) => {
    await browser.open("/dragging")
    const dragged = await browser.cell(`
      const page = tab.playwright
      await page.locator('#card').dragTo(page.locator('#bin'))
      const shot = await page.locator('#bin').screenshot()
      browser.write(await page.locator('#out').textContent() + '|' + shot.image.data.slice(0, 44))`)
    const [out, header = ""] = String(dragged).split("|")
    const png = Buffer.from(header, "base64")
    expect(out).toBe("dropped card")
    expect([png.readUInt32BE(16), png.readUInt32BE(20)]).toEqual([200, 100])
  })
})
