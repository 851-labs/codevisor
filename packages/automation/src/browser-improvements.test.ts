import { createServer, type ServerResponse } from "node:http"
import { mkdtempSync, rmSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it as baseIt, vi } from "vitest"
import { observeCdp } from "./browser-cdp-test-support.js"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
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

afterEach(() => {
  vi.unstubAllEnvs()
  vi.restoreAllMocks()
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
    vi.stubEnv("CODEVISOR_BROWSER_HEADLESS", "1")
    const cdp = observeCdp()
    const directory = mkdtempSync(join(tmpdir(), "browser-reliability-"))
    const provider = makeBrowserUseProvider(directory)
    const context = { sessionId: task.id, projectId: "reliability" }
    let origin: string
    const slow = Promise.withResolvers<ServerResponse>()
    const server = createServer((request, response) => {
      if (request.url === "/slow") {
        slow.resolve(response)
        return
      }
      response.setHeader("content-type", "text/html")
      const name = request.url?.includes("second") ? "Second" : "First"
      response.end(`<!doctype html><title>${name}</title>
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
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject)
        server.listen(0, resolve)
      })
      const address = server.address()
      if (!address || typeof address === "string") throw new Error("Missing fixture address")
      origin = `http://127.0.0.1:${address.port}`
      value(await provider.invoke(context, "use_backend", { backend: "managed" }))
      const cell = async (code: string) => value(await provider.invoke(context, "js", { code }))
      await cell(
        `var first = await browser.tabs.new(); await first.goto(${JSON.stringify(origin)})`
      )
      await use({ provider, context, origin, cell, cdp, slowResponse: slow.promise })
    } finally {
      try {
        await provider.close()
      } finally {
        server.closeAllConnections()
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve()))
        )
        rmSync(directory, { recursive: true, force: true })
      }
    }
  }
})

describe("Browser session reliability", () => {
  it("persists handles and targets concurrent operations at their own tabs", async ({
    browser: { cell, origin }
  }) => {
    await cell(
      `var second = await browser.tabs.new(); await second.goto(${JSON.stringify(origin + "/second")});`
    )
    expect(await cell("await Promise.all([first.title(), second.title()])")).toEqual([
      "First",
      "Second"
    ])
    expect(
      await cell(
        "await Promise.all([first.playwright.getByRole('textbox', {name:'Name',exact:true}).fill('left'), second.playwright.getByRole('textbox', {name:'Name',exact:true}).fill('right')]); await Promise.all([first.playwright.getByRole('textbox', {name:'Name',exact:true}).evaluate(e => e.value), second.playwright.getByRole('textbox', {name:'Name',exact:true}).evaluate(e => e.value)])"
      )
    ).toEqual(["left", "right"])
  })

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

  it("rejects refs from an older snapshot or a different tab", async ({
    browser: { cell, origin }
  }) => {
    await cell(
      `var second = await browser.tabs.new(); await second.goto(${JSON.stringify(origin + "/second")})`
    )
    const snapshot = String(await cell("await first.getAXState()"))
    const ref = snapshot.match(/button "No navigation" \[ref=(e\d+)\]/)?.[1]
    expect(ref).toBeTruthy()
    expect(snapshot).toContain('button "Deep action"')
    expect(snapshot).not.toContain("InlineTextBox")
    expect(snapshot).not.toContain('StaticText "Deep action"')
    await cell("await first.getAXState()")
    await expect(cell(`await first.click(${JSON.stringify(ref)})`)).rejects.toThrow(/stale/)
    const current = String(await cell("await first.getAXState()"))
    const currentRef = current.match(/button "No navigation" \[ref=(e\d+)\]/)?.[1]
    expect(currentRef).toBeTruthy()
    await cell("await second.getAXState()")
    await expect(cell(`await second.click(${JSON.stringify(currentRef)})`)).rejects.toThrow(/stale/)
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
    await cell(`await first.goto(${JSON.stringify(origin + "/frames")})`)
    expect(
      await cell(
        "await first.playwright.frameLocator('#outer').frameLocator('#inner').locator('#leaf').textContent()"
      )
    ).toBe("Nested content")
  })

  it("supports cross-origin frames", async ({ browser: { cell, origin } }) => {
    await cell(`await first.goto(${JSON.stringify(origin + "/cross")})`)
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

  it("does not substitute another tab after one closes", async ({ browser: { cell } }) => {
    await cell("var second = await browser.tabs.new()")
    await cell("await second.close()")
    await expect(cell("await second.title()")).rejects.toThrow(/own|closed/)
    expect(await cell("await first.title()")).toBe("First")
  })

  it("cleans scratch tabs at turn end while keeping marked output", async ({
    browser: { cell, provider, context }
  }) => {
    await cell("await first.markDeliverable(); var scratch = await browser.tabs.new();")
    const scratch = await cell("scratch.id")
    await provider.finishTurn?.(context.sessionId)
    const tabs = value<{ tabs: { id: string }[] }>(
      await provider.invoke(context, "tabs", { action: "list", scope: "session" })
    ).tabs
    expect(tabs.map((t) => t.id)).not.toContain(scratch)
    expect(tabs.map((t) => t.id)).toContain(await cell("first.id"))
    await cell("await first.close()")
  })
})
