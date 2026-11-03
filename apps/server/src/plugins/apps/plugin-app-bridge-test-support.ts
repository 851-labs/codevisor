import {
  installAppBridge,
  type BridgeBoot,
  type BridgeEvent,
  type BridgeRequestInit,
  type BridgeResponse
} from "./plugin-app-bridge.js"

export const boot: BridgeBoot = {
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
  framePath: "/v1/plugins/apps/view-1/frame?token=session-token",
  viewId: "view-1",
  toolInput: { range: "1h" },
  toolResult: { content: [{ type: "text", text: "2 alerts" }] },
  endpoints: {
    toolsCall: "/call",
    toolsList: "/tools",
    resourcesRead: "/read",
    modelContext: "/context",
    log: "/log"
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

export const json = (status: number, body: unknown): BridgeResponse => ({
  ok: status < 400,
  status,
  json: async () => body
})

export const bridged = (
  options: {
    readonly boot?: BridgeBoot
    readonly native?: boolean
    readonly pathname?: string
    readonly gesture?: boolean
    readonly respond?: (url: string, init: BridgeRequestInit) => Promise<BridgeResponse>
    readonly timeZone?: string
  } = {}
) => {
  const toApp: Array<Record<string, unknown>> = []
  const toNative: Array<unknown> = []
  const opened: Array<string> = []
  const fetched: Array<{ readonly url: string; readonly init: BridgeRequestInit }> = []
  const attributes: Record<string, string> = {}
  const replies = new Map<unknown, PromiseWithResolvers<Record<string, unknown>>>()
  let listener: ((event: BridgeEvent) => void) | undefined
  let resized: (() => void) | undefined
  const scheduled: Array<{ readonly callback: () => void; readonly delayMs: number }> = []
  let viewport = { width: 600, height: 240 }
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
    search: "?token=launch&theme=dark",
    frameOrigin: undefined,
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
      hasUserActivation: () => options.gesture ?? true,
      schedule: (callback, delayMs) => {
        scheduled.push({ callback, delayMs })
      },
      viewport: () => viewport,
      onResize: (changed) => {
        resized = changed
      },
      timeZone: () => options.timeZone
    }
  })
  const resize = (width: number, height: number) => {
    viewport = { width, height }
    resized?.()
  }
  const elapse = (delayMs: number) => {
    for (const timer of scheduled.filter((entry) => entry.delayMs === delayMs)) timer.callback()
  }
  const layout = (width: number, height: number) => {
    viewport = { width, height }
  }

  const fromApp = (data: unknown, source: unknown = contentWindow) => listener?.({ source, data })
  const request = (id: number, method: string, params?: unknown) => {
    const reply = Promise.withResolvers<Record<string, unknown>>()
    replies.set(id, reply)
    fromApp({ jsonrpc: "2.0", id, method, ...(params === undefined ? {} : { params }) })
    return reply.promise
  }

  return {
    api,
    attributes,
    elapse,
    fetched,
    frame,
    fromApp,
    layout,
    opened,
    request,
    resize,
    toApp,
    toNative
  }
}

export const initialized = (options: Parameters<typeof bridged>[0] = {}, appModes?: unknown) => {
  const opened = bridged(options)
  const init = opened.request(1, "ui/initialize", {
    appCapabilities: appModes === undefined ? {} : { availableDisplayModes: appModes }
  })
  opened.fromApp({ jsonrpc: "2.0", method: "ui/notifications/initialized" })
  opened.toApp.splice(0)
  opened.toNative.splice(0)
  return { ...opened, init }
}
