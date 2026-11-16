import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const app = `<title>App</title>
  <button id="save" onclick="fetch('/api/save?draft=7', { method: 'POST', body: 'title=Hello' })">Save</button>
  <button id="load" onclick="fetch('/api/items')">Load</button>
  <a id="open" href="/popup" target="_blank">Open</a>
  <button id="later" onclick="setTimeout(() => { window.loaded = { rows: 3 } }, 150)">Later</button>
  <button id="route" onclick="history.pushState({}, '', '/orders/42/done')">Route</button>`

const it = chromeBrowserSuite("page-waits", () => ({
  "/app": app,
  "/popup": "<title>Popup</title><h1>Opened</h1>",
  "/api/save?draft=7": "saved-body",
  "/api/items": "items-body"
}))

describe("Playwright page waits", () => {
  it("waits for the request and response an action causes, by glob, RegExp and predicate", async ({
    browser
  }) => {
    await browser.open("/app")
    const seen = await browser.cell(`
      const page = tab.playwright
      const path = (url) => url.replace(/^https?:\\/\\/[^/]+/, '').split('?')[0]
      const [response] = await Promise.all([page.waitForResponse('**/api/save*'), page.locator('#save').click()])
      const [request] = await Promise.all([page.waitForRequest(/\\/api\\/items$/), page.locator('#load').click()])
      const [picked] = await Promise.all([
        page.waitForResponse(candidate => candidate.url().endsWith('/api/items') && candidate.status() === 200),
        page.locator('#save').click().then(() => page.locator('#load').click())
      ])
      browser.write({
        response: [path(response.url()), response.status(), response.ok(), await response.text()],
        sent: [response.request().method(), response.request().postData()],
        request: [path(request.url()), request.method(), request.resourceType()],
        picked: await picked.text(),
        timedOut: await page.waitForResponse('**/never', { timeoutMs: 200 }).then(() => 'matched', (error) => error.message)
      })`)
    expect(seen).toEqual({
      response: ["/api/save", 200, true, "<!doctype html>saved-body"],
      sent: ["POST", "title=Hello"],
      request: ["/api/items", "GET", "fetch"],
      picked: "<!doctype html>items-body",
      timedOut: expect.stringContaining("Timed out waiting for a matching response")
    })
  })

  it("waits for a page function to turn truthy and returns its value", async ({ browser }) => {
    await browser.open("/app")
    const waited = await browser.cell(`
      const page = tab.playwright
      await page.locator('#later').click()
      browser.write({
        value: await page.waitForFunction(() => window.loaded),
        withArgument: await page.waitForFunction((least) => window.loaded.rows >= least && 'enough', 3),
        timedOut: await page.waitForFunction(() => window.never, undefined, { timeoutMs: 200 }).then(() => 'truthy', (error) => error.message)
      })`)
    expect(waited).toEqual({
      value: { rows: 3 },
      withArgument: "enough",
      timedOut: expect.stringContaining(
        "Timed out waiting for the function to return a truthy value"
      )
    })
  })

  it("hands back the tab a click opens, and matches URLs by pattern", async ({ browser }) => {
    await browser.open("/app")
    const opened = await browser.cell(`
      const page = tab.playwright
      const path = (url) => url.replace(/^https?:\\/\\/[^/]+/, '').split('?')[0]
      const [popup] = await Promise.all([page.waitForEvent('popup'), page.locator('#open').click()])
      await popup.playwright.waitForLoadState()
      await page.locator('#route').click()
      await page.waitForURL('**/orders/*/done')
      await page.waitForURL(/\\/orders\\/\\d+\\/done$/)
      browser.write({
        popup: [await popup.title(), await popup.playwright.locator('h1').textContent()],
        path: path(await tab.url()),
        wrongPattern: await page.waitForURL('**/orders/done', { timeoutMs: 200 }).then(() => 'matched', (error) => error.message)
      })`)
    expect(opened).toEqual({
      popup: ["Popup", "Opened"],
      path: "/orders/42/done",
      wrongPattern: expect.stringContaining(
        "Timed out waiting for page commit at the requested URL"
      )
    })
  })
})
