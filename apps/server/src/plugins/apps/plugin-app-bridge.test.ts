import { describe, expect, it } from "vitest"

import {
  installAppBridge,
  type BridgeBoot,
  type BridgeEvent,
  type BridgeRequestInit,
  type BridgeResponse
} from "./plugin-app-bridge.js"

const boot: BridgeBoot = {
  protocolVersion: "2026-01-26",
  hostInfo: { name: "Codevisor", version: "1.0.0" },
  hostCapabilities: { openLinks: {} },
  hostContext: {
    theme: "dark",
    displayMode: "inline",
    availableDisplayModes: ["inline", "fullscreen"]
  },
  html: "<p>app</p>",
  allow: "",
  token: "session-token",
  viewId: "view-1",
  toolInput: { range: "1h" },
  toolResult: { content: [{ type: "text", text: "2 alerts" }] },
  endpoints: { toolsCall: "/call", resourcesRead: "/read", modelContext: "/context" }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

const json = (status: number, body: unknown): BridgeResponse => ({
  ok: status < 400,
  status,
  json: async () => body
})

const bridged = (
  options: {
    readonly boot?: BridgeBoot
    readonly native?: boolean
    readonly pathname?: string
    readonly gesture?: boolean
    readonly respond?: (url: string, init: BridgeRequestInit) => Promise<BridgeResponse>
  } = {}
) => {
  const toApp: Array<Record<string, unknown>> = []
  const toNative: Array<unknown> = []
  const opened: Array<string> = []
  const fetched: Array<{ readonly url: string; readonly init: BridgeRequestInit }> = []
  const attributes: Record<string, string> = {}
  const replies = new Map<unknown, PromiseWithResolvers<Record<string, unknown>>>()
  let listener: ((event: BridgeEvent) => void) | undefined
  const contentWindow = {
    postMessage: (message: unknown) => {
      const record = isRecord(message) ? message : {}
      toApp.push(record)
      replies.get(record.id)?.resolve(record)
    }
  }
  const frame = {
    contentWindow,
    srcdoc: "",
    setAttribute: (name: string, value: string) => {
      attributes[name] = value
    }
  }

  const api = installAppBridge({
    pathname: options.pathname ?? "/v1/plugins/apps/view-1",
    boot: options.boot ?? boot,
    frame,
    host: {
      listen: (handler) => {
        listener = handler
      },
      fetch: (url, init) => {
        fetched.push({ url, init })
        return (options.respond ?? (async () => json(200, { ok: true })))(url, init)
      },
      post: (message) => {
        if (options.native === false) return false
        toNative.push(message)
        return true
      },
      open: (url) => opened.push(url),
      hasUserActivation: () => options.gesture ?? true
    }
  })

  const fromApp = (data: unknown, source: unknown = contentWindow) => listener?.({ source, data })
  const request = (id: number, method: string, params?: unknown) => {
    const reply = Promise.withResolvers<Record<string, unknown>>()
    replies.set(id, reply)
    fromApp({ jsonrpc: "2.0", id, method, ...(params === undefined ? {} : { params }) })
    return reply.promise
  }

  return { api, attributes, fetched, frame, fromApp, opened, request, toApp, toNative }
}

describe("plugin app bridge", () => {
  it("loads the app and answers ui/initialize with the host context", async () => {
    const { attributes, frame, request } = bridged()

    expect(frame.srcdoc).toBe("<p>app</p>")
    expect(attributes).toEqual({})
    expect(await request(1, "ui/initialize", {})).toEqual({
      jsonrpc: "2.0",
      id: 1,
      result: {
        protocolVersion: "2026-01-26",
        hostInfo: { name: "Codevisor", version: "1.0.0" },
        hostCapabilities: { openLinks: {} },
        hostContext: {
          theme: "dark",
          displayMode: "inline",
          availableDisplayModes: ["inline", "fullscreen"]
        }
      }
    })
  })

  it("sends the tool input and result once the app is initialized", () => {
    const { fromApp, toApp } = bridged()

    fromApp({ jsonrpc: "2.0", method: "ui/notifications/initialized" })
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/initialized" })

    expect(toApp).toEqual([
      {
        jsonrpc: "2.0",
        method: "ui/notifications/tool-input",
        params: { arguments: { range: "1h" } }
      },
      {
        jsonrpc: "2.0",
        method: "ui/notifications/tool-result",
        params: { content: [{ type: "text", text: "2 alerts" }] }
      }
    ])
  })

  it("sends panes no tool data", () => {
    const { toolInput: _input, toolResult: _result, ...pane } = boot
    const { attributes, fromApp, toApp } = bridged({
      boot: { ...pane, allow: "clipboard-write" }
    })

    fromApp({ jsonrpc: "2.0", method: "ui/notifications/initialized" })

    expect(toApp).toEqual([])
    expect(attributes).toEqual({ allow: "clipboard-write" })
  })

  it("proxies tools/call and resources/read to the host endpoints", async () => {
    const { fetched, request } = bridged()

    expect((await request(2, "tools/call", { name: "refresh" })).result).toEqual({ ok: true })
    expect((await request(3, "resources/read", { uri: "ui://x" })).result).toEqual({ ok: true })
    expect(fetched).toEqual([
      {
        url: "/call",
        init: {
          method: "POST",
          headers: { "content-type": "application/json", "x-codevisor-app-token": "session-token" },
          body: '{"name":"refresh"}'
        }
      },
      {
        url: "/read",
        init: {
          method: "POST",
          headers: { "content-type": "application/json", "x-codevisor-app-token": "session-token" },
          body: '{"uri":"ui://x"}'
        }
      }
    ])
  })

  it("resolves host endpoints under the path the shell was served from", async () => {
    const { fetched, request } = bridged({ pathname: "/machines/studio/v1/plugins/panes/t/" })

    await request(2, "tools/call", { name: "refresh" })

    expect(fetched.map(({ url }) => url)).toEqual(["/machines/studio/call"])
  })

  it("turns failed host calls into JSON-RPC errors", async () => {
    const failures = [
      async () => json(403, { error: "refresh isn't available to this app" }),
      async () => json(500, ["unexpected"]),
      () => Promise.reject("offline")
    ]
    const messages: Array<unknown> = []
    for (const respond of failures) {
      const { request } = bridged({ respond })
      messages.push((await request(4, "tools/call", { name: "refresh" })).error)
    }

    expect(messages).toEqual([
      { code: -32000, message: "refresh isn't available to this app" },
      { code: -32000, message: "Request failed (500)" },
      { code: -32000, message: "offline" }
    ])
  })

  it("opens links natively, or in a new window outside the app", async () => {
    const native = bridged()
    const browser = bridged({ native: false })

    expect(
      (await native.request(5, "ui/open-link", { url: "https://grafana.example" })).result
    ).toEqual({})
    await browser.request(6, "ui/open-link", { url: "mailto:oncall@example.com" })
    const rejected = await native.request(7, "ui/open-link", { url: "javascript:alert(1)" })
    const missing = await native.request(8, "ui/open-link", {})

    expect(native.toNative).toEqual([{ type: "openLink", url: "https://grafana.example" }])
    expect(browser.opened).toEqual(["mailto:oncall@example.com"])
    expect(rejected.error).toEqual({ code: -32000, message: "Invalid URL" })
    expect(missing.error).toEqual({ code: -32000, message: "Invalid URL" })
  })

  it("passes messages and size changes to the native app", async () => {
    const { fromApp, request, toNative } = bridged()

    await request(9, "ui/message", { role: "user", content: { type: "text", text: "Ack it" } })
    await request(10, "ui/message", { role: "user" })
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { height: 240 } })
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { width: 10 } })

    expect(toNative).toEqual([
      { type: "message", text: "Ack it", viewId: "view-1" },
      { type: "message", text: "", viewId: "view-1" },
      { type: "size", height: 240 }
    ])
  })

  it("posts messages to the chat only right after a gesture in the app", async () => {
    const idle = bridged({ gesture: false })
    const { viewId: _viewId, ...paneBoot } = boot
    const pane = bridged({ boot: paneBoot })

    const refused = await idle.request(1, "ui/message", { content: { type: "text", text: "Hi" } })
    await pane.request(1, "ui/message", { content: { type: "text", text: "Hi" } })

    expect(refused.error).toEqual({ code: -32000, message: "A user gesture is required" })
    expect(idle.toNative).toEqual([])
    expect(pane.toNative).toEqual([{ type: "message", text: "Hi" }])
  })

  it("forwards model context updates and answers pings", async () => {
    const { fetched, request } = bridged()

    expect(
      (await request(12, "ui/update-model-context", { structuredContent: { n: 1 } })).result
    ).toEqual({ ok: true })
    expect(fetched.map(({ url, init }) => [url, init.body])).toEqual([
      ["/context", '{"structuredContent":{"n":1}}']
    ])
    expect((await request(13, "ping")).result).toEqual({})
    expect((await request(14, "sampling/createMessage", {})).error).toEqual({
      code: -32601,
      message: "Method not found: sampling/createMessage"
    })
  })

  it("ignores messages from anywhere but the app frame", () => {
    const { fromApp, toApp, toNative } = bridged()

    fromApp({ jsonrpc: "2.0", id: 1, method: "ui/initialize" }, {})
    fromApp("hello")
    fromApp({ jsonrpc: "2.0", id: 2, result: {} })
    fromApp({ jsonrpc: "2.0", method: "notifications/message", params: { level: "info" } })

    expect(toApp).toEqual([])
    expect(toNative).toEqual([])
  })
})

const initialized = (options: Parameters<typeof bridged>[0] = {}, appModes?: unknown) => {
  const opened = bridged(options)
  const init = opened.request(1, "ui/initialize", {
    appCapabilities: appModes === undefined ? {} : { availableDisplayModes: appModes }
  })
  opened.fromApp({ jsonrpc: "2.0", method: "ui/notifications/initialized" })
  opened.toApp.splice(0)
  opened.toNative.splice(0)
  return { ...opened, init }
}

describe("plugin app display modes", () => {
  it("asks the native host to switch and answers with the mode it chose", async () => {
    const { api, request, toApp, toNative } = initialized()

    const switched = request(2, "ui/request-display-mode", { mode: "fullscreen" })
    api.displayModeChanged("fullscreen", "display-mode-1")

    expect(toNative).toEqual([
      { type: "displayMode", mode: "fullscreen", requestId: "display-mode-1" }
    ])
    expect((await switched).result).toEqual({ mode: "fullscreen" })
    expect(toApp[0]).toEqual({
      jsonrpc: "2.0",
      method: "ui/notifications/host-context-changed",
      params: { displayMode: "fullscreen" }
    })
  })

  it("answers with the current mode when the native host declines", async () => {
    const { api, request, toApp } = initialized()

    const declined = request(2, "ui/request-display-mode", { mode: "fullscreen" })
    api.displayModeChanged("inline", "display-mode-1")

    expect((await declined).result).toEqual({ mode: "inline" })
    expect(toApp.filter((message) => message.method !== undefined)).toEqual([])
  })

  it("never offers a mode outside the host's or the app's list", async () => {
    const host = initialized()
    const app = initialized({}, ["inline"])
    const appless = initialized({}, "everything")
    const headless = initialized({ native: false })
    const listless = initialized({
      boot: { ...boot, hostContext: { theme: "dark", displayMode: "inline" } }
    })

    const answers = await Promise.all([
      host.request(2, "ui/request-display-mode", { mode: "pip" }),
      host.request(3, "ui/request-display-mode", { mode: "inline" }),
      app.request(2, "ui/request-display-mode", { mode: "fullscreen" }),
      headless.request(2, "ui/request-display-mode", { mode: "fullscreen" }),
      listless.request(2, "ui/request-display-mode", { mode: "fullscreen" })
    ])
    const switched = appless.request(2, "ui/request-display-mode", { mode: "fullscreen" })
    appless.api.displayModeChanged("fullscreen", "display-mode-1")

    expect(answers.map(({ result }) => result)).toEqual(
      Array.from({ length: 5 }, () => ({ mode: "inline" }))
    )
    expect((await switched).result).toEqual({ mode: "fullscreen" })
    expect([...host.toNative, ...app.toNative]).toEqual([])
  })

  it("tells the app about unsolicited mode and theme changes", () => {
    const { api, toApp } = initialized()

    api.displayModeChanged("fullscreen")
    api.displayModeChanged("pip")
    api.setTheme("light")
    api.setTheme("light")
    api.setTheme("sepia")
    api.displayModeChanged("fullscreen", 7)

    expect(toApp.map(({ params }) => params)).toEqual([
      { displayMode: "fullscreen" },
      { theme: "light" }
    ])
  })

  it("holds context changes until the app is initialized, then reports them on initialize", async () => {
    const { api, request, toApp } = bridged()

    api.setTheme("light")
    api.displayModeChanged("fullscreen")

    expect(toApp).toEqual([])
    expect((await request(1, "ui/initialize", {})).result).toMatchObject({
      hostContext: { theme: "light", displayMode: "fullscreen" }
    })
  })
})
