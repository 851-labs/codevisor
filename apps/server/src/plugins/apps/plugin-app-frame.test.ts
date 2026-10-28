import { describe, expect, it } from "vitest"

import { installAppBridge, type BridgeBoot } from "./plugin-app-bridge.js"
import { appFrameOrigin } from "./plugin-app-shell.js"

const boot: BridgeBoot = {
  protocolVersion: "2026-01-26",
  hostInfo: { name: "Codevisor", version: "1.0.0" },
  hostCapabilities: {},
  hostContext: { theme: "dark", displayMode: "inline" },
  html: "<p>app</p>",
  allow: "",
  token: "session-token",
  framePath: "/v1/plugins/apps/view-1/frame?token=session-token",
  endpoints: { toolsCall: "/call", resourcesRead: "/read", modelContext: "/context" }
}

const mounted = (frameOrigin: string | undefined, framePath = boot.framePath) => {
  const attributes: Record<string, string> = {}
  const toNative: Array<unknown> = []
  const timers: Array<() => void> = []
  let listener: ((event: { source: unknown; data: unknown }) => void) | undefined
  const contentWindow = { postMessage: () => undefined }
  const frame = {
    contentWindow,
    srcdoc: "",
    setAttribute: (name: string, value: string) => {
      attributes[name] = value
    }
  }
  installAppBridge({
    boot: { ...boot, framePath },
    frame,
    pathname: "/relay/m1/v1/plugins/apps/view-1",
    search: "?token=launch&theme=dark",
    frameOrigin,
    host: {
      listen: (handler) => {
        listener = handler
      },
      fetch: () => Promise.reject(new Error("offline")),
      post: (message) => toNative.push(message) > 0,
      open: () => undefined,
      hasUserActivation: () => false,
      schedule: (callback) => {
        timers.push(callback)
      }
    }
  })
  const tick = () => timers.splice(0).forEach((callback) => callback())
  const ping = () =>
    listener?.({ source: contentWindow, data: { method: "codevisor/frame-ready" } })
  return { attributes, frame, tick, ping, toNative, timers }
}

describe("plugin app frame", () => {
  it("loads the app from the twin loopback origin so it gets a real origin of its own", () => {
    expect(appFrameOrigin("http://127.0.0.1:5123/v1/plugins/apps/v?token=a")).toBe(
      "http://localhost:5123"
    )
    expect(appFrameOrigin("http://localhost:5123/x")).toBe("http://127.0.0.1:5123")
    expect(appFrameOrigin("https://mac.example.ts.net/x")).toBeUndefined()

    const { attributes, frame } = mounted("http://localhost:5123")

    expect(frame.srcdoc).toBe("")
    expect(attributes).toEqual({
      sandbox: "allow-scripts allow-forms allow-same-origin",
      src: "http://localhost:5123/relay/m1/v1/plugins/apps/view-1/frame?token=session-token&token=launch&theme=dark"
    })
  })

  it("reloads a frame that never answers once, then tells the native host it failed", () => {
    const { attributes, tick, toNative, timers } = mounted("http://localhost:5123")
    delete attributes.src

    tick()
    expect(attributes.src).toContain("/frame?token=session-token")
    expect(toNative).toEqual([])

    tick()
    expect(toNative).toEqual([{ type: "frameFailed" }])
    expect(timers).toEqual([])
  })

  it("adds the display to a pane frame path that has no query of its own", () => {
    const { attributes } = mounted("http://localhost:5123", "/v1/plugins/panes/tok/frame")

    expect(attributes.src).toBe(
      "http://localhost:5123/relay/m1/v1/plugins/panes/tok/frame?token=launch&theme=dark"
    )
  })

  it("leaves a frame alone once its preamble checks in", () => {
    const { frame, ping, tick, toNative } = mounted(undefined)

    expect(frame.srcdoc).toBe("<p>app</p>")
    ping()
    tick()

    expect(toNative).toEqual([])
  })
})
