import { mkdtempSync, rmSync } from "node:fs"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { afterAll, beforeAll, describe, expect, it, onTestFinished, vi } from "vitest"

import { observeCdp } from "./browser-cdp-test-support.js"
import { makeBrowserUseProvider } from "./browser-use-provider.js"
import { expectArray, expectRecord, expectString, recordOrUndefined } from "./unknown-values.js"

const value = (result: CallToolResult): unknown => {
  const message = result.content
    .filter((content) => content.type === "text")
    .map((content) => content.text)
    .join("\n")
  if (result.isError) throw new Error(message)
  try {
    return JSON.parse(message)
  } catch {
    return message
  }
}

const tabsIn = (result: CallToolResult) =>
  expectArray(expectRecord(value(result), "Tabs").tabs, "Tabs").map((tab) =>
    expectRecord(tab, "Tab")
  )

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
    const firstFrame = Promise.withResolvers<void>()
    const openerActive = Promise.withResolvers<void>()
    const subscription = provider.subscribePreview!("preview", {
      status: (status) => {
        const label = `${status.state}:${status.title}`
        states.push(label)
        if (label === "active:Opener") openerActive.resolve()
      },
      frame: (data) => {
        frames.push(data)
        firstFrame.resolve()
      }
    })
    try {
      subscription.watch(800)
      value(await provider.invoke(context, "use_backend", { backend: "managed" }))
      value(await provider.invoke(context, "tabs", { action: "new", url: `${origin}/` }))
      await firstFrame.promise
      expect(Buffer.from(frames[0]!, "base64").subarray(0, 3).toString("hex")).toBe("ffd8ff")
      await openerActive.promise
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
    const shows = (label: string) =>
      seen.at(-1) === label
        ? Promise.resolve()
        : new Promise<void>((resolve) => waiters.push({ label, resolve }))
    try {
      subscription.watch(800)
      value(await provider.invoke(context, "use_backend", { backend: "managed" }))
      const opened = tabsIn(
        await provider.invoke(context, "tabs", { action: "new", url: `${origin}/` })
      )
      const first = expectString(opened.find((tab) => tab.selected === true)?.id, "Selected tab")
      const second = shows("active:Second")
      value(await provider.invoke(context, "tabs", { action: "new", url: `${origin}/second` }))
      await second

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
    const cdp = observeCdp()
    onTestFinished(() => {
      vi.restoreAllMocks()
    })
    const tabs = async () => tabsIn(await provider.invoke(context, "tabs", { action: "list" }))
    value(await provider.invoke(context, "use_backend", { backend: "managed" }))
    expect(await tabs()).toEqual([])

    const opened = tabsIn(await provider.invoke(context, "tabs", { action: "new" }))
    const openerId = expectString(opened.find((tab) => tab.selected === true)?.id, "Selected tab")
    const navigation = expectRecord(
      value(await provider.invoke(context, "playwright.armNavigation", {})),
      "Navigation baseline"
    )
    value(await provider.invoke(context, "navigate", { url: `${origin}/` }))
    value(
      await provider.invoke(context, "playwright.waitForNavigation", {
        afterSequence: navigation.afterSequence,
        frameId: navigation.frameId,
        url: `${origin}/`,
        waitUntil: "domcontentloaded"
      })
    )
    const popup = cdp.event("Target.targetCreated", (params) => {
      const info = recordOrUndefined(params.targetInfo)
      return info?.type === "page" && info.openerId === openerId
    })
    value(await provider.invoke(context, "playwright.click", { locator: { css: "#open" } }))
    await popup
    expect(await tabs()).toHaveLength(2)

    await provider.finishTurn?.("cleanup")
    expect(await tabs()).toEqual([])
  })
})
