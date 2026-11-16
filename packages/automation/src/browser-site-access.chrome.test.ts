import { createServer } from "node:http"

import { describe, expect, onTestFinished } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const it = chromeBrowserSuite("site-access", () => ({}))

const expectedLogin = `Basic ${Buffer.from("user:secret").toString("base64")}`

const protectedSite = async (): Promise<string> => {
  const server = createServer((request, response) => {
    if (request.headers.authorization !== expectedLogin) {
      response.writeHead(401, { "www-authenticate": 'Basic realm="staging"' }).end()
      return
    }
    response.setHeader("content-type", "text/html")
    response.end("<!doctype html><title>Staging</title><h1>Signed in</h1>")
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(async () => {
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  })
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("No TCP address")
  return `http://127.0.0.1:${address.port}`
}

describe("HTTP authentication", () => {
  it("opens a protected page with the credentials passed to goto, and keeps them for the tab", async ({
    browser
  }) => {
    const site = await protectedSite()
    const visits = await browser.cell(`
      const site = ${JSON.stringify(site)}
      const visit = (options) => tab.goto(site + '/admin', options).then(() => tab.title(), (error) => error.message)
      browser.write({
        withoutLogin: await visit(),
        wrongPassword: await visit({ httpCredentials: { username: 'user', password: 'wrong' } }),
        signedIn: await visit({ httpCredentials: { username: 'user', password: 'secret' } }),
        nextVisit: await visit()
      })`)
    const refused = expect.stringContaining(
      "This page asks for a username and password (HTTP authentication)"
    )
    expect(visits).toEqual({
      withoutLogin: refused,
      wrongPassword: refused,
      signedIn: "Staging",
      nextVisit: "Staging"
    })
  })
})
