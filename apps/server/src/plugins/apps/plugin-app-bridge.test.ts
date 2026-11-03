import { describe, expect, it } from "vitest"

import { boot, bridged, initialized, json } from "./plugin-app-bridge-test-support.js"

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
          availableDisplayModes: ["inline", "fullscreen"],
          containerDimensions: { width: 600 }
        }
      }
    })
  })

  it("tells the app its time zone and how far it may grow inside the host's container", async () => {
    const { request } = bridged({ boot: { ...boot, maxHeight: 720 }, timeZone: "America/New_York" })

    expect((await request(1, "ui/initialize", {})).result).toMatchObject({
      hostContext: {
        timeZone: "America/New_York",
        containerDimensions: { width: 600, maxHeight: 720 }
      }
    })
  })

  it("reports settled container width changes, not an inline app's own height or a hidden view", () => {
    const { elapse, fromApp, resize, toApp } = bridged({ boot: { ...boot, maxHeight: 720 } })
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/initialized" })
    toApp.splice(0)

    resize(600, 480)
    elapse(120)
    resize(0, 0)
    elapse(120)
    resize(380, 480)
    resize(420, 480)
    elapse(120)

    expect(toApp).toEqual([
      {
        jsonrpc: "2.0",
        method: "ui/notifications/host-context-changed",
        params: { containerDimensions: { width: 420, maxHeight: 720 } }
      }
    ])
  })

  it("sends the tool input and result each time the app initializes, so a reloaded app gets them too", () => {
    const { fromApp, toApp } = bridged()
    const toolData = [
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
    ]

    expect(toApp).toEqual([])
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/initialized" })
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/initialized" })

    expect(toApp).toEqual([...toolData, ...toolData])
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
    await request(10, "ui/message", {
      role: "user",
      content: [
        { type: "text", text: "Compare these" },
        { type: "image", data: "", mimeType: "image/png" },
        { type: "text", text: "two hosts" }
      ]
    })
    const blank = await request(11, "ui/message", {
      role: "user",
      content: [{ type: "text", text: " " }]
    })
    const missing = await request(12, "ui/message", { role: "user" })
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { height: 240 } })
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { width: 10 } })

    expect(toNative).toEqual([
      { type: "message", text: "Ack it", viewId: "view-1" },
      { type: "message", text: "Compare these\n\ntwo hosts", viewId: "view-1" },
      { type: "size", height: 240 }
    ])
    for (const refused of [blank, missing]) {
      expect(refused.error).toEqual({ code: -32000, message: "Invalid message format" })
    }
  })

  it("sizes the app to its measured content until the app reports a size itself", () => {
    const { fromApp, toNative } = bridged()
    const measured = (height: unknown) =>
      fromApp({
        jsonrpc: "2.0",
        method: "codevisor/notifications/content-size",
        params: { height }
      })

    measured(520)
    measured("tall")
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { width: 10 } })
    measured(560)
    fromApp({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { height: 300 } })
    measured(600)

    expect(toNative).toEqual([
      { type: "size", height: 520 },
      { type: "size", height: 560 },
      { type: "size", height: 300 }
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

  it("lists the app's tools and keeps its log messages through the host endpoints", async () => {
    const { fetched, fromApp, request } = bridged({
      respond: async () => {
        throw new Error("offline")
      }
    })

    const listed = await request(4, "tools/list", {})
    fromApp({
      jsonrpc: "2.0",
      method: "notifications/message",
      params: { level: "warning", data: "slow" }
    })
    await Promise.resolve()

    expect(listed.error).toEqual({ code: -32000, message: "offline" })
    expect(fetched.map(({ url, init }) => [url, init.body])).toEqual([
      ["/tools", "{}"],
      ["/log", '{"level":"warning","data":"slow"}']
    ])
  })

  it("tells the native host the app's border preference and when the app asks to close", () => {
    const framed = bridged({ boot: { ...boot, prefersBorder: false } })
    const plain = bridged()

    framed.fromApp({ jsonrpc: "2.0", method: "ui/notifications/request-teardown", params: {} })

    expect(framed.toNative).toEqual([
      { type: "prefersBorder", value: false },
      { type: "requestTeardown" }
    ])
    expect(plain.toNative).toEqual([])
  })

  it("warns the app before teardown and waits for its reply or a second at most", async () => {
    const early = bridged()
    const { api, elapse, fromApp, toApp } = initialized()

    await early.api.teardown("closed")
    const replied = api.teardown("closed")
    const silent = api.teardown("evicted")
    fromApp({ jsonrpc: "2.0", id: "teardown-1", result: {} })
    fromApp({ jsonrpc: "2.0", id: 99, result: {} })
    await replied
    elapse(1_000)
    await silent

    expect(early.toApp).toEqual([])
    expect(toApp.filter(({ method }) => method === "ui/resource-teardown")).toEqual([
      {
        jsonrpc: "2.0",
        id: "teardown-1",
        method: "ui/resource-teardown",
        params: { reason: "closed" }
      },
      {
        jsonrpc: "2.0",
        id: "teardown-2",
        method: "ui/resource-teardown",
        params: { reason: "evicted" }
      }
    ])
  })

  it("ignores messages from anywhere but the app frame", async () => {
    const { fromApp, request, toApp, toNative } = bridged()

    fromApp({ jsonrpc: "2.0", id: 1, method: "ping" }, {})
    fromApp("hello")
    fromApp({ jsonrpc: "2.0", id: 2, result: {} })
    fromApp({ jsonrpc: "2.0", method: "notifications/message", params: { level: "info" } })
    await request(3, "ping")

    expect(toApp.map((message) => message.id)).toEqual([3])
    expect(toNative).toEqual([])
  })
})
