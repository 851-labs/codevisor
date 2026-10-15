import { mkdtempSync, rmSync, readFileSync } from "node:fs"
import { createServer, type ServerResponse } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { afterAll, beforeAll, describe, expect, it as baseIt, vi } from "vitest"

import { emulateBrowserFocus, observeCdp } from "./browser-cdp-test-support.js"
import { makeBrowserUseProvider } from "./browser-use-provider.js"
import { expectRecord, expectString, recordOrEmpty } from "./unknown-values.js"

const value = (result: CallToolResult): unknown => {
  const message = result.content
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n")
  if (result.isError) throw new Error(message)
  try {
    return JSON.parse(message)
  } catch {
    return message
  }
}

const projectId = "reliability"
let provider: ReturnType<typeof makeBrowserUseProvider>
let cdp: ReturnType<typeof observeCdp>
let origin: string
let slow = Promise.withResolvers<ServerResponse>()
let directory: string
const server = createServer((request, response) => {
  if (request.url === "/slow") {
    slow.resolve(response)
    return
  }
  response.setHeader("content-type", "text/html")
  response.end(`<!doctype html><title>First</title>
      <button id="noop">No navigation</button><button id="push" onclick="history.pushState({},'', '/pushed')">Push</button>
      <button id="request" onclick="fetch('/slow')">Request</button><button id="change" onclick="document.querySelector('#noop').remove()">Change</button>
      <label>Name<input id="name" onkeydown="document.querySelector('#keys').textContent += event.key + ','"></label><p id="keys"></p>
      <form onsubmit="event.preventDefault(); document.querySelector('#submitted').textContent = this.query.value"><input aria-label="Query" name="query"></form><p id="submitted"></p>
      ${"<div>".repeat(40)}<button id="deep">Deep action</button>${"</div>".repeat(40)}
      <section id="ordered"><div><div><button aria-label="Repeated">Nested first</button></div></div><button aria-label="Repeated">Shallow second</button></section>
      <p class="entry">One</p><p class="entry">Two</p>
      ${request.url === "/frames" ? `<iframe id="outer" src="/inner"></iframe>` : ""}
      ${request.url === "/inner" ? `<iframe id="inner" src="/leaf"></iframe>` : ""}
      ${request.url === "/leaf" ? '<p id="leaf">Nested content</p><button id="leaf-button" onclick="this.textContent=123">Click frame</button><label>Frame input<input id="leaf-input"></label>' : ""}
      ${request.url === "/cross" ? `<iframe id="cross" src="${origin.replace("127.0.0.1", "localhost")}/leaf"></iframe>` : ""}
    `)
})

beforeAll(async () => {
  emulateBrowserFocus()
  cdp = observeCdp()
  directory = mkdtempSync(join(tmpdir(), "browser-reliability-"))
  provider = makeBrowserUseProvider(directory)
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", resolve)
  })
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("Missing fixture address")
  origin = `http://127.0.0.1:${address.port}`
  const warmup = { sessionId: "warmup", projectId }
  value(await provider.invoke(warmup, "use_backend", { backend: "managed" }))
  value(await provider.invoke(warmup, "tabs", { action: "list" }))
})

afterAll(async () => {
  try {
    await provider?.close()
  } finally {
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
    rmSync(directory, { recursive: true, force: true })
    vi.restoreAllMocks()
  }
})

const it = baseIt.extend<{
  browser: {
    context: { sessionId: string; projectId: string }
    cell: (code: string) => Promise<unknown>
    slowResponse: Promise<ServerResponse>
  }
}>({
  browser: async ({ task }, use) => {
    const context = { sessionId: task.id, projectId }
    slow = Promise.withResolvers<ServerResponse>()
    const cell = async (code: string) => value(await provider.invoke(context, "js", { code }))
    try {
      value(await provider.invoke(context, "use_backend", { backend: "managed" }))
      await cell(
        `var first = await browser.tabs.new(); await first.playwright.expectNavigation(() => first.goto(${JSON.stringify(origin)}), {waitUntil: 'domcontentloaded'})`
      )
      await use({ context, cell, slowResponse: slow.promise })
    } finally {
      await provider.closeSession(context.sessionId)
    }
  }
})

describe("Browser session reliability", () => {
  it("orders role matches by document order rather than AX response depth", async ({
    browser: { cell }
  }) => {
    expect(
      await cell(
        "await first.playwright.locator('#ordered').getByRole('button', {name:'Repeated',exact:true}).first().textContent()"
      )
    ).toBe("Nested first")
    expect(
      await cell(
        "await first.playwright.locator('#ordered').getByRole('button', {name:'Repeated',exact:true}).nth(1).textContent()"
      )
    ).toBe("Shallow second")
  })

  it("snapshots deeply nested controls without duplicate accessibility text", async ({
    browser: { cell }
  }) => {
    const snapshot = String(await cell("await first.getAXState()"))
    const ref = snapshot.match(/button "No navigation" \[ref=(e\d+)\]/)?.[1]
    expect(ref).toBeTruthy()
    expect(snapshot).toContain('button "Deep action"')
    expect(snapshot).not.toContain("InlineTextBox")
    expect(snapshot).not.toContain('StaticText "Deep action"')
  })

  it("observes same-document navigation after arming before the action", async ({
    browser: { cell }
  }) => {
    await cell(
      "await first.playwright.expectNavigation(() => first.playwright.locator('#push').click(), {waitUntil: 'commit'})"
    )
    expect(await cell("await first.url()")).toBe(origin + "/pushed")
  })

  it("observes network request completion through real CDP events", async ({
    browser: { cell, slowResponse }
  }) => {
    let requestId: unknown
    const requested = cdp.event("Network.requestWillBeSent", (params) => {
      if (String(recordOrEmpty(params.request).url).endsWith("/slow")) {
        requestId = params.requestId
        return true
      }
      return false
    })
    await cell("await first.playwright.locator('#request').click()")
    await requested
    const finished = cdp.event(
      "Network.loadingFinished",
      (params) => params.requestId === requestId
    )
    ;(await slowResponse).end("ready")
    await finished
    await cell("await first.playwright.waitForLoadState({state:'networkidle'})")
  })

  it("evaluates all matches and types individual key events", async ({ browser: { cell } }) => {
    expect(
      await cell(
        "await first.playwright.locator('.entry').evaluateAll(elements => elements.map(e => e.textContent))"
      )
    ).toEqual(["One", "Two"])
    await cell(
      "await first.playwright.locator('#name').fill(''); await first.playwright.locator('#name').pressSequentially('Ab +')"
    )
    expect(await cell("await first.playwright.locator('#keys').textContent()")).toBe("A,b, ,+,")
    expect(await cell("await first.playwright.locator('#name').evaluate(e => e.value)")).toBe(
      "Ab +"
    )
  })

  it("submits a form through a trusted Enter press", async ({ browser: { cell } }) => {
    await cell(
      "await first.playwright.getByRole('textbox', {name:'Query',exact:true}).fill('Search terms'); await first.playwright.getByRole('textbox', {name:'Query',exact:true}).press('Enter')"
    )
    expect(await cell("await first.playwright.locator('#submitted').textContent()")).toBe(
      "Search terms"
    )
  })

  it("exports real files using the binary attachment contract", async ({
    browser: { cell, context }
  }) => {
    const result = await provider.invoke(context, "content.export", {
      format: "markdown",
      tabId: await cell("first.id")
    })
    const file = expectRecord(expectRecord(value(result), "Export").file, "Exported file")
    expect(readFileSync(expectString(file.path, "Exported path"), "utf8")).toContain(
      "Source: " + origin
    )
    expect(result.content.some((c) => c.type === "resource")).toBe(true)
  })

  it("supports nested frames", async ({ browser: { cell } }) => {
    await cell(
      `await first.playwright.expectNavigation(() => first.goto(${JSON.stringify(origin + "/frames")}), {waitUntil: 'load'})`
    )
    expect(
      await cell(
        "await first.playwright.frameLocator('#outer').frameLocator('#inner').locator('#leaf').textContent()"
      )
    ).toBe("Nested content")
  })

  it("supports cross-origin frames", async ({ browser: { cell } }) => {
    await cell(
      `await first.playwright.expectNavigation(() => first.goto(${JSON.stringify(origin + "/cross")}), {waitUntil: 'load'})`
    )
    expect(
      await cell("await first.playwright.frameLocator('#cross').locator('#leaf').textContent()")
    ).toBe("Nested content")
    await cell("await first.playwright.frameLocator('#cross').locator('#leaf-button').click()")
    expect(
      await cell(
        "await first.playwright.frameLocator('#cross').locator('#leaf-button').textContent()"
      )
    ).toBe("123")
    await cell(
      "await first.playwright.frameLocator('#cross').locator('#leaf-input').fill('frame typing')"
    )
    expect(
      await cell(
        "await first.playwright.frameLocator('#cross').locator('#leaf-input').evaluate(e => e.value)"
      )
    ).toBe("frame typing")
  })
})
