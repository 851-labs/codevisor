import { mkdtempSync, rmSync } from "node:fs"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { afterAll, beforeAll, describe, expect, it as baseIt } from "vitest"

import { makeBrowserUseProvider } from "./browser-use-provider.js"

const toolsPage = `<!doctype html><title>Shop</title>
<p id="cart">empty</p>
<p id="aborted">no</p>
<form toolname="search_products" tooldescription="Search the catalog">
  <input name="query" toolparamdescription="Search text" required>
  <button type="submit">Search</button>
</form>
<form id="subscribe" toolname="subscribe" tooldescription="Subscribe to the newsletter" toolautosubmit>
  <input name="email" type="email" toolparamdescription="Email address" required>
  <button type="submit">Subscribe</button>
</form>
<script>
document.querySelector("#subscribe").addEventListener("submit", (event) => {
  event.preventDefault()
  event.respondWith(Promise.resolve("subscribed " + new FormData(event.target).get("email")))
})
document.modelContext.registerTool({
  name: "add_to_cart",
  description: "Add a product to the cart",
  inputSchema: {
    type: "object",
    properties: { sku: { type: "string" }, qty: { type: "integer", minimum: 1 } },
    required: ["sku"]
  },
  annotations: { readOnlyHint: false },
  execute: async ({ sku, qty = 1 }) => {
    document.querySelector("#cart").textContent = qty + " x " + sku
    return { content: [{ type: "text", text: "added " + qty + " of " + sku }] }
  }
})
document.modelContext.registerTool({
  name: "wait_forever",
  description: "Never finishes until canceled",
  execute: (_input, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => {
      document.querySelector("#aborted").textContent = "yes"
      reject(new Error("aborted"))
    })
  })
})
document.modelContext.registerTool({
  name: "explode",
  description: "Always throws",
  execute: async () => { throw new Error("out of stock") }
})
</script>`

const emptyPage = `<!doctype html><title>Plain</title><p>No tools here</p>`

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

const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html" })
  response.end(request.url === "/plain" ? emptyPage : toolsPage)
})
const directory = mkdtempSync(join(tmpdir(), "browser-webmcp-"))
const previousHeadless = process.env.CODEVISOR_BROWSER_HEADLESS
const projectId = "webmcp"
let provider: ReturnType<typeof makeBrowserUseProvider>
let origin = ""

beforeAll(async () => {
  process.env.CODEVISOR_BROWSER_HEADLESS = "1"
  provider = makeBrowserUseProvider(directory, "http://127.0.0.1:43210")
  await new Promise<void>((resolve) => server.listen(0, "localhost", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("Missing fixture address")
  origin = `http://localhost:${address.port}`
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

const it = baseIt.extend<{ cell: (code: string) => Promise<unknown> }>({
  cell: async ({ task }, use) => {
    const context = { sessionId: task.id, projectId }
    const cell = async (code: string) => value(await provider.invoke(context, "js", { code }))
    try {
      value(await provider.invoke(context, "use_backend", { backend: "managed" }))
      await cell(
        `var tab = await browser.tabs.new(); await tab.playwright.expectNavigation(() => tab.goto(${JSON.stringify(origin)}), { waitUntil: "load" })`
      )
      await use(cell)
    } finally {
      await provider.closeSession(context.sessionId)
    }
  }
})

const rejection = (call: string) => `await ${call}.then(() => "resolved", (error) => error.message)`

describe("WebMCP site tools", () => {
  it("lists the page's imperative and form tools", async ({ cell }) => {
    const listing = await cell("await tab.webmcp.list()")

    expect(listing).toEqual({
      tools: expect.arrayContaining([
        {
          name: "add_to_cart",
          description: "Add a product to the cart",
          inputSchema: {
            type: "object",
            properties: { sku: { type: "string" }, qty: { type: "integer", minimum: 1 } },
            required: ["sku"]
          },
          annotations: expect.objectContaining({ readOnly: false })
        },
        expect.objectContaining({ name: "wait_forever" }),
        expect.objectContaining({ name: "explode" }),
        expect.objectContaining({
          name: "search_products",
          inputSchema: expect.objectContaining({ required: ["query"] })
        }),
        expect.objectContaining({ name: "subscribe", annotations: { autosubmit: true } })
      ])
    })
    expect(
      await cell("(await tab.capabilities.list()).map((capability) => capability.id)")
    ).toContain("webmcp")
  })

  it("calls an imperative tool and returns what the page produced", async ({ cell }) => {
    const outcome = await cell('await tab.webmcp.call("add_to_cart", { sku: "A1", qty: 2 })')

    expect(outcome).toEqual({
      status: "completed",
      result: { content: [{ type: "text", text: "added 2 of A1" }] }
    })
    expect(await cell("await tab.playwright.locator('#cart').textContent()")).toBe("2 x A1")
  })

  it("rejects input that doesn't match the tool's schema before the page sees it", async ({
    cell
  }) => {
    const message = await cell(rejection('tab.webmcp.call("add_to_cart", { qty: "lots" })'))

    expect(message).toContain("Invalid input for add_to_cart")
    expect(message).toContain("sku")
    expect(await cell("await tab.playwright.locator('#cart').textContent()")).toBe("empty")
  })

  it("reports unknown tools and tools that throw", async ({ cell }) => {
    expect(await cell(rejection('tab.webmcp.call("checkout")'))).toContain(
      "No WebMCP tool named checkout"
    )
    expect(await cell(rejection('tab.webmcp.call("explode")'))).toContain(
      "explode failed: Error: out of stock"
    )
  })

  it("submits autosubmit forms and reports forms that wait for the user", async ({ cell }) => {
    expect(await cell('await tab.webmcp.call("subscribe", { email: "a@example.com" })')).toEqual({
      status: "completed",
      result: "subscribed a@example.com"
    })

    const pending = await cell('await tab.webmcp.call("search_products", { query: "socks" })')

    expect(pending).toMatchObject({ status: "awaitingUserSubmit" })
    expect(
      await cell(
        "await tab.playwright.locator('input[name=query]').evaluate((input) => input.value)"
      )
    ).toBe("socks")
  })

  it("cancels a tool that outlives its timeout", async ({ cell }) => {
    const message = await cell(
      rejection('tab.webmcp.call("wait_forever", {}, { timeoutMs: 1000 })')
    )

    expect(message).toContain("wait_forever didn't finish within 1000 ms, so it was canceled")
    await cell(
      "await tab.playwright.getByText('yes', { exact: true }).waitFor({ state: 'visible' })"
    )
  })

  it("explains an empty list on a page without tools", async ({ cell }) => {
    await cell(
      `await tab.playwright.expectNavigation(() => tab.goto(${JSON.stringify(`${origin}/plain`)}), { waitUntil: "load" })`
    )

    expect(await cell("await tab.webmcp.list()")).toEqual({
      tools: [],
      reason: "This page registers no WebMCP tools."
    })
  })
})
