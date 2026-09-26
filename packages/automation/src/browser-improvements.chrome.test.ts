import { mkdtempSync, rmSync, readFileSync } from "node:fs"
import { createServer, type ServerResponse } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { afterAll, beforeAll, describe, expect, it as baseIt, vi } from "vitest"

import { emulateBrowserFocus, observeCdp } from "./browser-cdp-test-support.js"
import { makeBrowserUseProvider } from "./browser-use-provider.js"

const value = <T = unknown>(result: CallToolResult): T => {
  const message = result.content
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n")
  if (result.isError) throw new Error(message)
  try {
    return JSON.parse(message) as T
  } catch {
    return message as T
  }
}

/// One Chrome for the whole file: managed Chrome is shared per project, so
/// each test gets its own agent session and tab (the production model)
/// instead of paying a cold browser start inside its own time budget.
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
  // Installed before the browser exists so every connection and tab is observed.
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
  // Start Chrome here, under the hook budget, rather than inside a test.
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
    provider: ReturnType<typeof makeBrowserUseProvider>
    context: { sessionId: string; projectId: string }
    origin: string
    cell: (code: string) => Promise<unknown>
    cdp: ReturnType<typeof observeCdp>
    slowResponse: Promise<ServerResponse>
  }
}>({
  browser: async ({ task }, use) => {
    const context = { sessionId: task.id, projectId }
    slow = Promise.withResolvers<ServerResponse>()
    const cell = async (code: string) => value(await provider.invoke(context, "js", { code }))
    try {
      value(await provider.invoke(context, "use_backend", { backend: "managed" }))
      // Establish the fixture document before testing tab reads. Page.navigate
      // can return while the previous about:blank document is still interactive.
      await cell(
        `var first = await browser.tabs.new(); await first.playwright.expectNavigation(() => first.goto(${JSON.stringify(origin)}), {waitUntil: 'domcontentloaded'})`
      )
      await use({ provider, context, origin, cell, cdp, slowResponse: slow.promise })
    } finally {
      // Closes this session's tabs so the next test starts clean.
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

  // Handle persistence, concurrent routing, and stale refs have controlled
  // fixtures in browser-repl.test.ts and browser-tab-routing.test.ts. Keep the
  // real Chrome assertion here for its accessibility tree and DOM integration.
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
    browser: { cell, origin }
  }) => {
    await cell(
      "await first.playwright.expectNavigation(() => first.playwright.locator('#push').click(), {waitUntil: 'commit'})"
    )
    expect(await cell("await first.url()")).toBe(origin + "/pushed")
  })

  it("observes network request completion through real CDP events", async ({
    browser: { cell, cdp, slowResponse }
  }) => {
    let requestId: unknown
    const requested = cdp.event("Network.requestWillBeSent", (params) => {
      if ((params.request as { url: string }).url.endsWith("/slow")) {
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
    browser: { cell, provider, context, origin }
  }) => {
    const result = await provider.invoke(context, "content.export", {
      format: "markdown",
      tabId: await cell("first.id")
    })
    const exported = value<{ file: { path: string } }>(result)
    expect(readFileSync(exported.file.path, "utf8")).toContain("Source: " + origin)
    expect(result.content.some((c) => c.type === "resource")).toBe(true)
  })

  it("supports nested frames", async ({ browser: { cell, origin } }) => {
    await cell(
      `await first.playwright.expectNavigation(() => first.goto(${JSON.stringify(origin + "/frames")}), {waitUntil: 'load'})`
    )
    expect(
      await cell(
        "await first.playwright.frameLocator('#outer').frameLocator('#inner').locator('#leaf').textContent()"
      )
    ).toBe("Nested content")
  })

  it("supports cross-origin frames", async ({ browser: { cell, origin } }) => {
    // The load event includes the child frame's navigation and process swap.
    // Reading immediately after Page.navigate can still see its blank document.
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
