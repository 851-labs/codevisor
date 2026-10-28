export interface BridgeBoot {
  readonly protocolVersion: string
  readonly hostInfo: { readonly name: string; readonly version: string }
  readonly hostCapabilities: Readonly<Record<string, unknown>>
  readonly hostContext: Readonly<Record<string, unknown>>
  readonly html: string
  readonly allow: string
  readonly token: string
  readonly viewId?: string
  readonly toolInput?: Readonly<Record<string, unknown>>
  readonly toolResult?: Readonly<Record<string, unknown>>
  readonly framePath: string
  readonly endpoints: {
    readonly toolsCall: string
    readonly resourcesRead: string
    readonly modelContext: string
  }
}

export interface CodevisorHostApi {
  readonly displayModeChanged: (mode: unknown, requestId?: unknown) => void
  readonly setTheme: (theme: unknown) => void
}

export interface BridgeWindow {
  readonly postMessage: (message: unknown, targetOrigin: string) => void
}

export interface BridgeFrame {
  readonly contentWindow: BridgeWindow | null
  srcdoc: string
  readonly setAttribute: (name: string, value: string) => void
}

export interface BridgeEvent {
  readonly source: unknown
  readonly data: unknown
}

export interface BridgeResponse {
  readonly ok: boolean
  readonly status: number
  readonly json: () => Promise<unknown>
}

export interface BridgeRequestInit {
  readonly method: string
  readonly headers: Readonly<Record<string, string>>
  readonly body: string
}

export interface BridgeHost {
  readonly listen: (handler: (event: BridgeEvent) => void) => void
  readonly fetch: (url: string, init: BridgeRequestInit) => Promise<BridgeResponse>
  readonly post: (message: Readonly<Record<string, unknown>>) => boolean
  readonly open: (url: string) => void
  readonly hasUserActivation: () => boolean
  readonly schedule: (callback: () => void, delayMs: number) => void
}

export interface BridgeEnv {
  readonly boot: BridgeBoot
  readonly pathname: string
  readonly search: string
  readonly frameOrigin: string | undefined
  readonly frame: BridgeFrame
  readonly host: BridgeHost
}

type Params = Readonly<Record<string, unknown>>

export const installAppBridge = (env: BridgeEnv): CodevisorHostApi => {
  const { boot, frame, host } = env
  const mount = env.pathname.indexOf("/v1/plugins/")
  const basePath = mount > 0 ? env.pathname.slice(0, mount) : ""
  const context: Record<string, unknown> = { ...boot.hostContext }
  const declaredHostModes = boot.hostContext.availableDisplayModes
  const hostModes: ReadonlyArray<unknown> = Array.isArray(declaredHostModes)
    ? declaredHostModes
    : []
  const modeRequests = new Map<string, (mode: unknown) => void>()
  let appModes: ReadonlyArray<unknown> | undefined
  let nextModeRequest = 0
  let initialized = false

  // oxlint-disable-next-line unicorn/consistent-function-scoping
  const isRecord = (value: unknown): value is Params =>
    typeof value === "object" && value !== null && !Array.isArray(value)

  const recordOf = (value: unknown): Params => (isRecord(value) ? value : {})

  const send = (message: Params): void => {
    frame.contentWindow?.postMessage({ jsonrpc: "2.0", ...message }, "*")
  }

  const forward = async (url: string, params: Params): Promise<unknown> => {
    const response = await host.fetch(`${basePath}${url}`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-codevisor-app-token": boot.token },
      body: JSON.stringify(params)
    })
    const body = recordOf(await response.json())
    if (response.ok) return body
    const reason =
      typeof body.error === "string" ? body.error : `Request failed (${response.status})`
    throw new Error(reason)
  }

  const openLink = (params: Params): Params => {
    const url = typeof params.url === "string" ? params.url : ""
    if (!/^(https?:|mailto:)/i.test(url)) throw new Error("Invalid URL")
    if (!host.post({ type: "openLink", url })) host.open(url)
    return {}
  }

  const sendMessage = (params: Params): Params => {
    if (!host.hasUserActivation()) throw new Error("A user gesture is required")
    const text = recordOf(params.content).text
    host.post({
      type: "message",
      text: typeof text === "string" ? text : "",
      ...(boot.viewId === undefined ? {} : { viewId: boot.viewId })
    })
    return {}
  }

  const initialize = (params: Params): Params => {
    const declared = recordOf(params.appCapabilities).availableDisplayModes
    appModes = Array.isArray(declared) ? declared : undefined
    if (appModes !== undefined) host.post({ type: "appModes", modes: [...appModes] })
    return {
      protocolVersion: boot.protocolVersion,
      hostInfo: boot.hostInfo,
      hostCapabilities: boot.hostCapabilities,
      hostContext: { ...context }
    }
  }

  const modeAllowed = (mode: unknown): boolean =>
    hostModes.includes(mode) && (appModes === undefined || appModes.includes(mode))

  const requestDisplayMode = (params: Params): Params | Promise<Params> => {
    const mode = params.mode
    if (mode === context.displayMode || !modeAllowed(mode)) return { mode: context.displayMode }
    nextModeRequest += 1
    const requestId = `display-mode-${nextModeRequest}`
    const changed = new Promise<Params>((resolve) => {
      modeRequests.set(requestId, (actual) => resolve({ mode: actual }))
    })
    if (host.post({ type: "displayMode", mode, requestId })) return changed
    modeRequests.delete(requestId)
    return { mode: context.displayMode }
  }

  const requests = new Map<string, (params: Params) => unknown>([
    ["ui/initialize", initialize],
    ["tools/call", (params) => forward(boot.endpoints.toolsCall, params)],
    ["resources/read", (params) => forward(boot.endpoints.resourcesRead, params)],
    ["ui/open-link", openLink],
    ["ui/message", sendMessage],
    ["ui/request-display-mode", requestDisplayMode],
    ["ui/update-model-context", (params) => forward(boot.endpoints.modelContext, params)],
    ["ping", () => ({})]
  ])

  const deliverToolData = (): void => {
    initialized = true
    if (boot.toolInput !== undefined) {
      send({ method: "ui/notifications/tool-input", params: { arguments: boot.toolInput } })
    }
    if (boot.toolResult !== undefined) {
      send({ method: "ui/notifications/tool-result", params: boot.toolResult })
    }
  }

  const reportSize = (params: Params): void => {
    if (typeof params.height === "number") host.post({ type: "size", height: params.height })
  }

  const notifications = new Map<string, (params: Params) => void>([
    ["ui/notifications/initialized", deliverToolData],
    ["ui/notifications/size-changed", reportSize]
  ])

  const answer = async (id: unknown, method: string, params: Params): Promise<void> => {
    const handler = requests.get(method)
    if (handler === undefined) {
      send({ id, error: { code: -32601, message: `Method not found: ${method}` } })
      return
    }
    try {
      send({ id, result: await handler(params) })
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause)
      send({ id, error: { code: -32000, message } })
    }
  }

  let frameAlive = false
  let frameAttempts = 0

  host.listen((event) => {
    if (event.source !== frame.contentWindow) return
    frameAlive = true
    const message = recordOf(event.data)
    if (typeof message.method !== "string") return
    const params = recordOf(message.params)
    if (message.id === undefined) {
      notifications.get(message.method)?.(params)
      return
    }
    void answer(message.id, message.method, params)
  })

  const changeContext = (changes: Params): void => {
    Object.assign(context, changes)
    if (initialized) send({ method: "ui/notifications/host-context-changed", params: changes })
  }

  const displayModeChanged = (mode: unknown, requestId?: unknown): void => {
    if (hostModes.includes(mode) && mode !== context.displayMode) {
      changeContext({ displayMode: mode })
    }
    const key = typeof requestId === "string" ? requestId : ""
    const settle = modeRequests.get(key)
    modeRequests.delete(key)
    settle?.(context.displayMode)
  }

  const setTheme = (theme: unknown): void => {
    if ((theme === "light" || theme === "dark") && theme !== context.theme) {
      changeContext({ theme })
    }
  }

  const mountFrame = (): void => {
    frameAttempts += 1
    if (env.frameOrigin === undefined) {
      frame.srcdoc = boot.html
    } else {
      const display = env.search.replace(/^\?/, "")
      const separator = boot.framePath.includes("?") ? "&" : "?"
      frame.setAttribute("sandbox", "allow-scripts allow-forms allow-same-origin")
      frame.setAttribute(
        "src",
        `${env.frameOrigin}${basePath}${boot.framePath}${separator}${display}`
      )
    }
    host.schedule(checkFrame, 10_000)
  }

  const checkFrame = (): void => {
    if (frameAlive) return
    if (frameAttempts < 2) {
      mountFrame()
      return
    }
    host.post({ type: "frameFailed" })
  }

  if (boot.allow !== "") frame.setAttribute("allow", boot.allow)
  mountFrame()
  return { displayModeChanged, setTheme }
}
