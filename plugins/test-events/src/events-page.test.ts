import { runInNewContext } from "node:vm"

import { describe, expect, it } from "vitest"

import { eventsPageHtml, eventsPageScript } from "./events-page.js"

interface FakeElement {
  textContent: string
  children: Array<FakeElement>
  replaceChildren(...children: Array<FakeElement>): void
}

const element = (): FakeElement => ({
  textContent: "",
  children: [],
  replaceChildren(...children) {
    this.children = children
  }
})

const loadPage = () => {
  const posted: Array<Record<string, unknown>> = []
  const listeners: Array<(event: { data: unknown }) => void> = []
  const elements: Record<string, FakeElement> = { events: element(), status: element() }
  const window = {
    parent: { postMessage: (message: Record<string, unknown>) => posted.push(message) },
    addEventListener: (_type: string, listener: (event: { data: unknown }) => void) =>
      listeners.push(listener)
  }
  const document = { getElementById: (id: string) => elements[id], createElement: element }
  runInNewContext(eventsPageScript, { window, document })
  const receive = async (data: unknown) => {
    for (const listener of listeners) listener({ data })
    await new Promise((resolve) => setImmediate(resolve))
  }
  return { posted, receive, elements }
}

const events = [{ timestamp: "2026-10-27T12:00:00.000Z", name: "test.ping", data: { count: 1 } }]

describe("events page", () => {
  it("embeds the bridge script in the served html", () => {
    expect(eventsPageHtml).toContain(`<script>${eventsPageScript}</script>`)
  })

  it("initializes over the Apps bridge, then loads and renders recent events", async () => {
    const page = loadPage()

    expect(page.posted[0]).toMatchObject({
      jsonrpc: "2.0",
      id: 1,
      method: "ui/initialize",
      params: {
        appInfo: { name: "test-events" },
        appCapabilities: {},
        protocolVersion: "2026-01-26"
      }
    })
    await page.receive({ jsonrpc: "2.0", id: 1, result: { hostContext: {} } })
    expect(page.posted.slice(1)).toMatchObject([
      { method: "ui/notifications/initialized" },
      { id: 2, method: "tools/call", params: { name: "list_recent", arguments: {} } }
    ])

    await page.receive({ jsonrpc: "2.0", id: 2, result: { structuredContent: { events } } })
    expect(page.elements["events"]?.children.map((child) => child.textContent)).toEqual([
      '2026-10-27T12:00:00.000Z  test.ping  {"count":1}'
    ])
    expect(page.elements["status"]?.textContent).toBe("1 recent events")
  })

  it("re-renders on tool results and ignores unrelated messages", async () => {
    const page = loadPage()
    await page.receive({ jsonrpc: "2.0", id: 1, result: {} })
    await page.receive({ jsonrpc: "2.0", id: 2, result: {} })

    await page.receive("not json-rpc")
    await page.receive({ jsonrpc: "2.0", method: "ui/notifications/tool-input", params: {} })
    expect(page.elements["status"]?.textContent).toBe("0 recent events")

    await page.receive({
      jsonrpc: "2.0",
      method: "ui/notifications/tool-result",
      params: { structuredContent: { events } }
    })
    expect(page.elements["events"]?.children).toHaveLength(1)
  })

  it("shows the error when the host rejects initialization", async () => {
    const page = loadPage()

    await page.receive({ jsonrpc: "2.0", id: 1, error: { code: -32000, message: "denied" } })

    expect(page.elements["status"]?.textContent).toBe("denied")
  })
})
