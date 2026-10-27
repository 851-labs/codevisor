import type { PluginAppView } from "@codevisor/mcp"

export const OPENAI_GLOBALS_EVENT = "openai:set_globals"

export interface ShimMessage {
  readonly source: unknown
  readonly data: unknown
}

export interface ShimWindow {
  openai?: unknown
  readonly addEventListener: (type: "message", handler: (event: ShimMessage) => void) => void
  readonly dispatchEvent: (event: unknown) => boolean
}

export interface ShimParent {
  readonly postMessage: (message: unknown, targetOrigin: string) => void
}

export interface ShimEnv {
  readonly window: ShimWindow
  readonly parent: ShimParent
  readonly globals: Readonly<Record<string, unknown>>
  readonly globalsEvent: (globals: Readonly<Record<string, unknown>>) => unknown
}

type Params = Readonly<Record<string, unknown>>

interface Waiter {
  readonly resolve: (value: unknown) => void
  readonly reject: (cause: Error) => void
}

export const openAiGlobals = (
  hostContext: Readonly<Record<string, unknown>>,
  view: PluginAppView | undefined
): Record<string, unknown> => ({
  theme: hostContext.theme,
  displayMode: hostContext.displayMode,
  locale: hostContext.locale ?? "en-US",
  userAgent: "Codevisor",
  safeArea: { insets: { top: 0, right: 0, bottom: 0, left: 0 } },
  toolInput: view?.toolInput ?? {},
  toolOutput: view?.toolResult.structuredContent ?? null,
  toolResponseMetadata: view?.toolResult._meta ?? null,
  widgetState: null
})

export const openAiShimScript = (globalsJson: string): string =>
  [
    "<script>",
    `(${installOpenAiShim.toString()})({`,
    "window,",
    "parent: window.parent,",
    `globals: ${globalsJson},`,
    `globalsEvent: (globals) => new CustomEvent("${OPENAI_GLOBALS_EVENT}", { detail: { globals } })`,
    "});",
    "</script>"
  ].join("\n")

export const installOpenAiShim = (env: ShimEnv): void => {
  const globals: Record<string, unknown> = { ...env.globals }
  const pending = new Map<string, Waiter>()
  let nextId = 0

  // oxlint-disable-next-line unicorn/consistent-function-scoping
  const recordOf = (value: unknown): Params => {
    if (typeof value !== "object" || value === null || Array.isArray(value)) return {}
    return Object.fromEntries(Object.entries(value))
  }

  const post = (message: Params): void => {
    env.parent.postMessage({ jsonrpc: "2.0", ...message }, "*")
  }

  const request = (method: string, params: Params): Promise<unknown> => {
    nextId += 1
    const id = `codevisor-openai-${nextId}`
    const reply = new Promise<unknown>((resolve, reject) => pending.set(id, { resolve, reject }))
    post({ id, method, params })
    return reply
  }

  const settle = (message: Params): boolean => {
    const id = message.id
    const waiter = typeof id === "string" ? pending.get(id) : undefined
    if (waiter === undefined) return false
    pending.delete(String(id))
    if (message.error === undefined) {
      waiter.resolve(message.result)
      return true
    }
    const reason = recordOf(message.error).message
    waiter.reject(new Error(typeof reason === "string" ? reason : "Request failed"))
    return true
  }

  const api: Record<string, unknown> = {
    ...globals,
    callTool: (name: string, args?: Params) =>
      request("tools/call", { name, arguments: args ?? {} }),
    sendFollowUpMessage: async (options: Params) => {
      const text = typeof options.prompt === "string" ? options.prompt : ""
      await request("ui/message", { role: "user", content: { type: "text", text } })
    },
    openExternal: async (options: Params) => {
      await request("ui/open-link", { url: options.href })
    },
    requestDisplayMode: (options: Params) =>
      request("ui/request-display-mode", { mode: options.mode }),
    notifyIntrinsicHeight: (height: unknown) => {
      post({ method: "ui/notifications/size-changed", params: { height } })
    },
    setWidgetState: async (state: unknown) => {
      changeGlobals({ widgetState: state })
      await request("ui/update-model-context", { structuredContent: recordOf(state) })
    }
  }

  const changeGlobals = (changes: Params): void => {
    Object.assign(globals, changes)
    Object.assign(api, changes)
    env.window.dispatchEvent(env.globalsEvent(changes))
  }

  const contextKeys = new Set(["theme", "displayMode", "locale"])

  const updates = new Map<string, (params: Params) => Params>([
    ["ui/notifications/tool-input", (params) => ({ toolInput: recordOf(params.arguments) })],
    [
      "ui/notifications/tool-result",
      (params) => ({
        toolOutput: params.structuredContent ?? null,
        toolResponseMetadata: params._meta ?? null
      })
    ],
    [
      "ui/notifications/host-context-changed",
      (params) => Object.fromEntries(Object.entries(params).filter(([key]) => contextKeys.has(key)))
    ]
  ])

  env.window.addEventListener("message", (event) => {
    if (event.source !== env.parent) return
    const message = recordOf(event.data)
    if (settle(message)) return
    const change = typeof message.method === "string" ? updates.get(message.method) : undefined
    if (change !== undefined) changeGlobals(change(recordOf(message.params)))
  })

  env.window.openai = api
}
