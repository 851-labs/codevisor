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

const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html" })
  response.end(
    request.url === "/second"
      ? `<!doctype html><title>Second</title>`
      : `<!doctype html><title>Opener</title><button id="open" onclick="window.open('about:blank')">Open</button>`
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

describe("Browser live preview", () => {
  it("streams the agent's tab while it works, then stops when the turn ends", async () => {
    const context = { sessionId: "preview", projectId: "preview" }
    const states: string[] = []
    const frames: string[] = []
    const subscription = provider.subscribePreview!("preview", {
      status: (status) => states.push(`${status.state}:${status.title}`),
      frame: (data) => frames.push(data)
    })
    try {
      subscription.watch(800)
      value(await provider.invoke(context, "use_backend", { backend: "managed" }))
      value(await provider.invoke(context, "tabs", { action: "new", url: `${origin}/` }))
      for (let attempt = 0; frames.length === 0 && attempt < 100; attempt += 1)
        await new Promise((resolve) => setTimeout(resolve, 50))
      // JPEG frames of the agent's tab, titled after its page.
      expect(Buffer.from(frames[0]!, "base64").subarray(0, 3).toString("hex")).toBe("ffd8ff")
      for (let attempt = 0; !states.includes("active:Opener") && attempt < 100; attempt += 1)
        await new Promise((resolve) => setTimeout(resolve, 50))
      expect(states).toContain("active:Opener")

      await provider.finishTurn?.("preview")
      expect(states.at(-1)).toBe("stopped:Opener")
      const settled = frames.length
      value(await provider.invoke(context, "tabs", { action: "list" }))
      expect(frames).toHaveLength(settled)
    } finally {
      subscription.close()
    }
  })
})

describe("Browser live preview across tabs", () => {
  it("moves to the tab a call names, not only the selected one", async () => {
    const context = { sessionId: "preview-tabs", projectId: "preview-tabs" }
    const seen: string[] = []
    const waiters: Array<{ readonly label: string; readonly resolve: () => void }> = []
    const subscription = provider.subscribePreview!("preview-tabs", {
      status: (status) => {
        const label = `${status.state}:${status.title}`
        seen.push(label)
        for (const waiter of waiters.filter((candidate) => candidate.label === label)) {
          waiters.splice(waiters.indexOf(waiter), 1)
          waiter.resolve()
        }
      },
      frame: () => undefined
    })
    /// Resolves on the next status with this label, or now if it is the latest.
    const shows = (label: string) =>
      seen.at(-1) === label
        ? Promise.resolve()
        : new Promise<void>((resolve) => waiters.push({ label, resolve }))
    try {
      subscription.watch(800)
      value(await provider.invoke(context, "use_backend", { backend: "managed" }))
      const opened = value<{ tabs: ReadonlyArray<{ id: string; selected: boolean }> }>(
        await provider.invoke(context, "tabs", { action: "new", url: `${origin}/` })
      )
      const first = opened.tabs.find((tab) => tab.selected)!.id
      const second = shows("active:Second")
      value(await provider.invoke(context, "tabs", { action: "new", url: `${origin}/second` }))
      await second

      // A REPL tab handle names its tab on every call; the selection stays.
      const back = shows("active:Opener")
      value(await provider.invoke(context, "tab_info", { tabId: first }))
      await back
    } finally {
      subscription.close()
      await provider.finishTurn?.("preview-tabs")
    }
  })
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
