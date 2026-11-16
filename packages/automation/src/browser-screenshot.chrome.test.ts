import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const it = chromeBrowserSuite("screenshot", () => ({
  "/blank": `<title>Blank</title><body style="margin:0;background:#fff;height:100vh"></body>`
}))

const paintedPixelsNear = `async (data, x, y) => {
  const image = new Image()
  image.src = 'data:image/png;base64,' + data
  await image.decode()
  const canvas = new OffscreenCanvas(image.width, image.height)
  const context = canvas.getContext('2d')
  context.drawImage(image, 0, 0)
  const pixels = context.getImageData(x - 4, y - 4, 40, 40).data
  let painted = 0
  for (let index = 0; index < pixels.length; index += 4) {
    if (pixels[index] < 250 || pixels[index + 1] < 250 || pixels[index + 2] < 250) painted += 1
  }
  return painted
}`

describe("Screenshots", () => {
  it("leaves the agent's pointer out of the picture and puts it back afterwards", async ({
    browser
  }) => {
    await browser.open("/blank")
    const result = await browser.cell(`
      await tab.cua.click({ x: 300, y: 200 })
      await tab.playwright.waitForTimeout(900)
      const cdp = await tab.capabilities.get('cdp')
      const evaluate = async (expression) =>
        (await cdp.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result.value
      const layerShown = () => evaluate("getComputedStyle(document.getElementById('codevisor-pointer-layer')).visibility")
      const before = await layerShown()
      const shot = await tab.screenshot()
      const painted = await evaluate('(' + ${JSON.stringify(paintedPixelsNear)} + ')(' + JSON.stringify(shot.image.data) + ', 300, 200)')
      browser.write({ before, painted, after: await layerShown() })`)
    expect(result).toEqual({ before: "visible", painted: 0, after: "visible" })
  })
})
