import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const boardPage = `<title>Board</title><p id="out">none</p>
  <div id="card" draggable="true" style="width:80px;height:40px;background:#9cf">card</div>
  <div id="lane" style="width:160px;height:80px;margin-top:60px;border:2px dashed #888">lane</div>
  <script>
    const seen = []
    const note = (event) => {
      if (!seen.includes(event.type)) seen.push(event.type)
      document.querySelector('#out').textContent = seen.join(' ')
    }
    for (const type of ['dragstart', 'dragenter', 'dragover', 'drop', 'dragend'])
      document.addEventListener(type, note, true)
    document.querySelector('#card').ondragstart = (event) => event.dataTransfer.setData('text/plain', 'card-1')
    const lane = document.querySelector('#lane')
    lane.ondragover = (event) => event.preventDefault()
    lane.ondrop = (event) => { event.preventDefault(); lane.textContent = event.dataTransfer.getData('text/plain') }
  </script>`

const it = chromeBrowserSuite("drag", () => ({ "/board": boardPage }))

describe("Drag and drop", () => {
  it("turns a mouse down, move and up into a real HTML5 drag and drop", async ({ browser }) => {
    await browser.open("/board")
    const dropped = await browser.cell(`
      const page = tab.playwright
      const centre = (selector) => page.locator(selector).evaluate(element => {
        const box = element.getBoundingClientRect()
        return { x: box.x + box.width / 2, y: box.y + box.height / 2 }
      })
      const card = await centre('#card')
      const lane = await centre('#lane')
      await page.mouse.move(card.x, card.y)
      await page.mouse.down()
      await page.mouse.move(lane.x, lane.y, { steps: 5 })
      await page.mouse.up()
      browser.write([await page.locator('#lane').textContent(), await page.locator('#out').textContent()])`)
    expect(dropped).toEqual(["card-1", "dragstart dragenter dragover drop dragend"])
  })
})
