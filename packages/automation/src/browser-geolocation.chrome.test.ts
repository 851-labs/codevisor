import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const it = chromeBrowserSuite("geolocation", () => ({
  "/map": "<title>Map</title><h1>Map</h1>"
}))

const locate = `async (owner) => {
  const cdp = await owner.capabilities.get('cdp')
  const expression = "new Promise(resolve => navigator.geolocation.getCurrentPosition(found => resolve([found.coords.latitude, found.coords.longitude, found.coords.accuracy].join(',')), failed => resolve('error ' + failed.code)))"
  return (await cdp.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result.value
}`

describe("Tab location", () => {
  it("answers a page's location request with the position given to the tab, on each site it visits", async ({
    browser
  }) => {
    const { origin, crossOrigin } = browser.origins
    await browser.open("/map")
    const located = await browser.cell(`
      const locate = ${locate}
      const seen = { before: await locate(tab) }
      await tab.setGeolocation({ latitude: 48.8584, longitude: 2.2945 })
      seen.shared = await locate(tab)
      await tab.goto(${JSON.stringify(`${crossOrigin}/map`)})
      seen.nextSite = await locate(tab)
      await tab.setGeolocation({ latitude: 40.6892, longitude: -74.0445, accuracy: 50 })
      seen.moved = await locate(tab)
      const other = await browser.tabs.new()
      await other.goto(${JSON.stringify(`${crossOrigin}/map`)})
      seen.tabWithoutOne = await locate(other)
      await other.close()
      await tab.setGeolocation(null)
      seen.cleared = await locate(tab)
      await tab.goto(${JSON.stringify(`${origin}/map`)})
      seen.firstSiteAgain = await locate(tab)
      browser.write(seen)`)
    expect(located).toEqual({
      before: "error 1",
      shared: "48.8584,2.2945,10",
      nextSite: "48.8584,2.2945,10",
      moved: "40.6892,-74.0445,50",
      tabWithoutOne: "error 2",
      cleared: "error 1",
      firstSiteAgain: "error 1"
    })
  })
})
