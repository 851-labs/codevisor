import { createServer } from "node:http"
import { mkdtempSync, rmSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterAll, beforeAll, describe, expect, it } from "vitest"
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

describe.sequential("Browser session reliability", () => {
  const directory = mkdtempSync(join(tmpdir(), "browser-reliability-"))
  const provider = makeBrowserUseProvider(directory)
  const context = { sessionId: "reliability", projectId: "reliability" }
  let origin: string
  const server = createServer((request, response) => {
    if (request.url === "/slow") {
      setTimeout(() => response.end("ready"), 900)
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
  beforeAll(async () => {
    await new Promise<void>((resolve) => server.listen(0, resolve))
    const address = server.address()
    if (!address || typeof address === "string") throw new Error("Missing fixture address")
    origin = `http://127.0.0.1:${address.port}`
    value(await provider.invoke(context, "use_backend", { backend: "managed" }))
  })
  afterAll(async () => {
    await provider.close()
    await new Promise<void>((resolve) => server.close(() => resolve()))
    rmSync(directory, { recursive: true, force: true })
  })
  const cell = async (code: string) => value(await provider.invoke(context, "js", { code }))

  it("persists handles and targets concurrent operations at their own tabs", async () => {
    await cell(
      `var first = await browser.tabs.new(); await first.goto(${JSON.stringify("PLACEHOLDER")});`.replace(
        '"PLACEHOLDER"',
        JSON.stringify(origin)
      )
    )
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

  it("orders role matches by document order rather than AX response depth", async () => {
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

  it("rejects refs from an older snapshot or a different tab", async () => {
    const snapshot = String(await cell("await first.getAXState()"))
    const ref = snapshot.match(/button "No navigation" \[ref=(e\d+)\]/)?.[1]
    expect(ref).toBeTruthy()
    expect(snapshot).toContain('button "Deep action"')
    expect(snapshot).not.toContain("InlineTextBox")
    expect(snapshot).not.toContain('StaticText "Deep action"')
    await cell("await first.getAXState()")
    await expect(cell(`await first.click(${JSON.stringify(ref)})`)).rejects.toThrow(/stale/)
    await cell("await second.getAXState()")
    await expect(cell(`await second.click(${JSON.stringify(ref)})`)).rejects.toThrow(/stale/)
  })

  it("requires an actual navigation and observes same-document navigation", async () => {
    await expect(
      cell(
        "await first.playwright.expectNavigation(() => first.playwright.locator('#noop').click(), {timeoutMs: 150})"
      )
    ).rejects.toThrow(/Timed out waiting for navigation/)
    await cell(
      "await first.playwright.expectNavigation(() => first.playwright.locator('#push').click(), {timeoutMs: 2000, waitUntil: 'commit'})"
    )
    expect(await cell("await first.url()")).toBe(origin + "/pushed")
  })

  it("waits for outstanding network requests and the quiet interval", async () => {
    const started = Date.now()
    await cell(
      "await first.playwright.locator('#request').click(); await first.playwright.waitForLoadState({state:'networkidle',timeoutMs:3000})"
    )
    expect(Date.now() - started).toBeGreaterThanOrEqual(1300)
  })

  it("evaluates all matches and types individual key events", async () => {
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

  it("submits a form through a trusted Enter press", async () => {
    await cell(
      "await first.playwright.getByRole('textbox', {name:'Query',exact:true}).fill('Search terms'); await first.playwright.getByRole('textbox', {name:'Query',exact:true}).press('Enter')"
    )
    expect(await cell("await first.playwright.locator('#submitted').textContent()")).toBe(
      "Search terms"
    )
  })

  it("exports real files using the binary attachment contract", async () => {
    const result = await provider.invoke(context, "content.export", {
      format: "markdown",
      tabId: await cell("first.id")
    })
    const exported = value<{ file: { path: string } }>(result)
    expect(readFileSync(exported.file.path, "utf8")).toContain("Source: " + origin)
    expect(result.content.some((c) => c.type === "resource")).toBe(true)
  })

  it("supports nested frames", async () => {
    await cell(`await first.goto(${JSON.stringify(origin + "/frames")})`)
    expect(
      await cell(
        "await first.playwright.frameLocator('#outer').frameLocator('#inner').locator('#leaf').textContent()"
      )
    ).toBe("Nested content")
  })

  it("supports cross-origin frames", async () => {
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

  it("does not substitute another tab after one closes", async () => {
    await cell("await second.close()")
    await expect(cell("await second.title()")).rejects.toThrow(/own|closed/)
    expect(await cell("await first.title()")).toBe("First")
  })

  it("cleans scratch tabs at turn end while keeping marked output", async () => {
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
