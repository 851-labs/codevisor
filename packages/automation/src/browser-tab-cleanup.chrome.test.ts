import { mkdtempSync, rmSync } from "node:fs"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { afterAll, beforeAll, describe, expect, it } from "vitest"

import { makeBrowserUseProvider } from "./browser-use-provider.js"

/// What a turn leaves behind in a real managed Chromium: no startup page, and
/// no agent tab or popup once the turn ends.
const value = <T = unknown>(result: CallToolResult): T => {
  const message = result.content
    .filter((content) => content.type === "text")
    .map((content) => content.text)
    .join("\n")
  if (result.isError) throw new Error(message)
  try {
    return JSON.parse(message) as T
  } catch {
    return message as T
  }
}

const server = createServer((_request, response) => {
  response.writeHead(200, { "content-type": "text/html" })
  response.end(
    `<!doctype html><title>Opener</title><button id="open" onclick="window.open('about:blank')">Open</button>`
  )
})
const directory = mkdtempSync(join(tmpdir(), "browser-tab-cleanup-"))
const previousHeadless = process.env.CODEVISOR_BROWSER_HEADLESS
let provider: ReturnType<typeof makeBrowserUseProvider>
let origin = ""

beforeAll(async () => {
  process.env.CODEVISOR_BROWSER_HEADLESS = "1"
  provider = makeBrowserUseProvider(directory)
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("Missing fixture address")
  origin = `http://127.0.0.1:${address.port}`
})

afterAll(async () => {
  try {
    await provider?.close()
  } finally {
    if (previousHeadless === undefined) delete process.env.CODEVISOR_BROWSER_HEADLESS
    else process.env.CODEVISOR_BROWSER_HEADLESS = previousHeadless
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
    rmSync(directory, { recursive: true, force: true })
  }
})

describe("Browser tab cleanup", () => {
  it("starts with no page and leaves no agent tab or popup after the turn", async () => {
    const context = { sessionId: "cleanup", projectId: "cleanup" }
    const tabs = async () =>
      value<{ tabs: ReadonlyArray<{ url: string }> }>(
        await provider.invoke(context, "tabs", { action: "list" })
      ).tabs
    value(await provider.invoke(context, "use_backend", { backend: "managed" }))
    expect(await tabs()).toEqual([])

    value(await provider.invoke(context, "tabs", { action: "new", url: `${origin}/` }))
    value(await provider.invoke(context, "playwright.click", { locator: { css: "#open" } }))
    let opened = await tabs()
    for (let attempt = 0; opened.length < 2 && attempt < 40; attempt += 1) opened = await tabs()
    expect(opened).toHaveLength(2)

    await provider.finishTurn?.("cleanup")
    expect(await tabs()).toEqual([])
  })
})
