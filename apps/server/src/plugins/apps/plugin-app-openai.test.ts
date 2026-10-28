import { runInNewContext } from "node:vm"

import type { PluginAppView } from "@codevisor/mcp"
import { describe, expect, it } from "vitest"

import {
  installOpenAiShim,
  openAiGlobals,
  openAiShimScript,
  type ShimMessage
} from "./plugin-app-openai.js"

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

type ShimFunction = (...args: Array<unknown>) => unknown

const isShimFunction = (value: unknown): value is ShimFunction => typeof value === "function"

const view: PluginAppView = {
  viewId: "0b9a8f8e-5d1c-4f43-9f53-3e1c2c7f2a10",
  machineId: "studio",
  sessionId: "session-1",
  serverId: "zillow",
  serverName: "Zillow",
  toolName: "zillow_property_search",
  resourceUri: "ui://widget/zillow-property-search.html",
  toolInput: { request: { displayLimit: 2 } },
  toolResult: {
    content: [{ type: "text", text: "2 homes" }],
    structuredContent: { results: [], resultCounts: { totalMatchingCount: 2 } },
    _meta: { "zillow.com/data": { widget: "search" } }
  },
  createdAt: "2026-10-27T12:00:00.000Z"
}

const shimmed = (globals: Record<string, unknown> = { theme: "dark" }) => {
  const toParent: Array<Record<string, unknown>> = []
  const events: Array<unknown> = []
  const parent = {
    postMessage: (message: unknown) => {
      if (isRecord(message)) toParent.push(message)
    }
  }
  let listener: ((event: ShimMessage) => void) | undefined
  const window: Parameters<typeof installOpenAiShim>[0]["window"] = {
    addEventListener: (_type, handler) => {
      listener = handler
    },
    dispatchEvent: (event) => {
      events.push(event)
      return true
    }
  }
  installOpenAiShim({ window, parent, globals, globalsEvent: (changes) => ({ changes }) })
  expect(toParent.splice(0)).toEqual([{ jsonrpc: "2.0", method: "codevisor/frame-ready" }])
  const openai = isRecord(window.openai) ? window.openai : {}
  const fromHost = (data: unknown, source: unknown = parent) => listener?.({ source, data })
  const method = (name: string): ShimFunction => {
    const value = openai[name]
    if (!isShimFunction(value)) throw new Error(`window.openai.${name} is missing`)
    return value
  }
  return { events, fromHost, method, openai, toParent }
}

describe("window.openai shim", () => {
  it("exposes the tool data and host context as Apps SDK globals", () => {
    expect(openAiGlobals({ theme: "dark", displayMode: "inline" }, view)).toEqual({
      theme: "dark",
      displayMode: "inline",
      locale: "en-US",
      userAgent: "Codevisor",
      safeArea: { insets: { top: 0, right: 0, bottom: 0, left: 0 } },
      toolInput: { request: { displayLimit: 2 } },
      toolOutput: { results: [], resultCounts: { totalMatchingCount: 2 } },
      toolResponseMetadata: { "zillow.com/data": { widget: "search" } },
      widgetState: null
    })
    expect(openAiGlobals({ locale: "fr-FR" }, undefined)).toMatchObject({
      locale: "fr-FR",
      toolInput: {},
      toolOutput: null,
      toolResponseMetadata: null
    })
    const { toolResult: _result, ...rest } = view
    expect(openAiGlobals({}, { ...rest, toolResult: { content: [] } })).toMatchObject({
      toolOutput: null,
      toolResponseMetadata: null
    })
    expect(shimmed().openai).toMatchObject({ theme: "dark" })
  })

  it("calls host tools over the app bridge and settles on the reply", async () => {
    const { fromHost, method, toParent } = shimmed()

    const called = method("callTool")("refresh", { all: true })
    const bare = method("callTool")("refresh")
    fromHost({ jsonrpc: "2.0", id: "codevisor-openai-1", result: { structuredContent: { ok: 1 } } })
    fromHost({ jsonrpc: "2.0", id: "codevisor-openai-2", error: { code: -32000, message: "nope" } })

    expect(toParent).toEqual([
      {
        jsonrpc: "2.0",
        id: "codevisor-openai-1",
        method: "tools/call",
        params: { name: "refresh", arguments: { all: true } }
      },
      {
        jsonrpc: "2.0",
        id: "codevisor-openai-2",
        method: "tools/call",
        params: { name: "refresh", arguments: {} }
      }
    ])
    await expect(called).resolves.toEqual({ structuredContent: { ok: 1 } })
    await expect(bare).rejects.toThrow("nope")
  })

  it("maps the other Apps SDK calls onto ui/* messages", async () => {
    const { events, fromHost, method, openai, toParent } = shimmed()
    const answer = (id: number, result: unknown = {}) =>
      fromHost({ jsonrpc: "2.0", id: `codevisor-openai-${id}`, result })

    const followUp = method("sendFollowUpMessage")({ prompt: "Tour it" })
    const blank = method("sendFollowUpMessage")({})
    const opened = method("openExternal")({ href: "https://www.zillow.com/homedetails/1" })
    const mode = method("requestDisplayMode")({ mode: "fullscreen" })
    method("notifyIntrinsicHeight")(480)
    const saved = method("setWidgetState")({ favorite: 7 })
    for (const id of [1, 2, 3]) answer(id)
    answer(4, { mode: "inline" })
    fromHost({ jsonrpc: "2.0", id: "codevisor-openai-5", error: {} })

    await Promise.all([followUp, blank, opened])
    await expect(saved).rejects.toThrow("Request failed")
    expect(await mode).toEqual({ mode: "inline" })
    expect(toParent.map(({ method: name, params }) => [name, params])).toEqual([
      ["ui/message", { role: "user", content: { type: "text", text: "Tour it" } }],
      ["ui/message", { role: "user", content: { type: "text", text: "" } }],
      ["ui/open-link", { url: "https://www.zillow.com/homedetails/1" }],
      ["ui/request-display-mode", { mode: "fullscreen" }],
      ["ui/notifications/size-changed", { height: 480 }],
      ["ui/update-model-context", { structuredContent: { favorite: 7 } }]
    ])
    expect(openai.widgetState).toEqual({ favorite: 7 })
    expect(events).toEqual([{ changes: { widgetState: { favorite: 7 } } }])
  })

  it("follows tool data and context the host sends later", () => {
    const { events, fromHost, openai } = shimmed()

    fromHost({
      jsonrpc: "2.0",
      method: "ui/notifications/tool-input",
      params: { arguments: { q: 1 } }
    })
    fromHost({
      jsonrpc: "2.0",
      method: "ui/notifications/tool-result",
      params: { content: [], structuredContent: { results: [1] }, _meta: { "zillow.com/data": {} } }
    })
    fromHost({ jsonrpc: "2.0", method: "ui/notifications/tool-result", params: { content: [] } })
    fromHost({
      jsonrpc: "2.0",
      method: "ui/notifications/host-context-changed",
      params: { theme: "light", platform: "mobile" }
    })

    expect(openai).toMatchObject({ toolInput: { q: 1 }, toolOutput: null, theme: "light" })
    expect(events).toEqual([
      { changes: { toolInput: { q: 1 } } },
      {
        changes: { toolOutput: { results: [1] }, toolResponseMetadata: { "zillow.com/data": {} } }
      },
      { changes: { toolOutput: null, toolResponseMetadata: null } },
      { changes: { theme: "light" } }
    ])
  })

  it("ignores messages that aren't host replies or updates", () => {
    const { events, fromHost, toParent } = shimmed()

    fromHost({ jsonrpc: "2.0", method: "ui/notifications/tool-input", params: {} }, {})
    fromHost("hello")
    fromHost({ jsonrpc: "2.0", id: 7, result: {} })
    fromHost({ jsonrpc: "2.0", id: "codevisor-openai-9", result: {} })
    fromHost({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: {} })

    expect(events).toEqual([])
    expect(toParent).toEqual([])
  })

  it("installs itself from the srcdoc script", () => {
    const script = openAiShimScript('{"theme":"dark"}')
    const posted: Array<unknown> = []
    const window = {
      addEventListener: () => undefined,
      dispatchEvent: () => true,
      parent: { postMessage: (message: unknown) => posted.push(message) }
    }
    class CustomEvent {
      constructor(
        readonly type: string,
        readonly init: unknown
      ) {}
    }

    runInNewContext(script.replace(/^<script>|<\/script>$/g, ""), { window, CustomEvent })

    expect(window).toMatchObject({ openai: { theme: "dark" } })
  })
})
