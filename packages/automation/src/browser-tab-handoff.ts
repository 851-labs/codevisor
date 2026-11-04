import type { BrowserRuntime } from "./browser-cdp-engine.js"
import type { BrowserToolSessionState } from "./browser-use-invoke-types.js"
import type { BrowserBackend } from "./browser-use-provider-types.js"

export interface TabHandoff {
  readonly keepIds: ReadonlySet<string>
  readonly keepsAll: boolean
  readonly frontId: string | undefined
}

export interface TabHandoffRequest {
  readonly backend: BrowserBackend
  readonly requestedKeepIds: ReadonlyArray<string>
  readonly sessionKey: string
  readonly state: BrowserToolSessionState
  readonly turnEnded: boolean
}

export const tabHandoff = (request: TabHandoffRequest): TabHandoff => {
  const { backend, requestedKeepIds, sessionKey, state, turnEnded } = request
  const dispositions = state.sessionDispositions.get(sessionKey) ?? new Map()
  const handoffIds = [...dispositions]
    .filter(([, status]) => status === "handoff")
    .map(([id]) => id)
  const visible = backend !== "managed"
  return {
    keepIds: new Set([...requestedKeepIds, ...dispositions.keys()]),
    keepsAll: turnEnded,
    frontId: visible ? handoffIds.at(-1) : undefined
  }
}

export const forgetTabHandoff = (state: BrowserToolSessionState, sessionKey: string): void => {
  state.sessionDispositions.delete(sessionKey)
}

export const bringTabToFront = (active: BrowserRuntime, targetId: string): Promise<unknown> =>
  active.connection
    .send("Target.activateTarget", { targetId })
    .catch(() => bringPageToFront(active, targetId))

const bringPageToFront = (active: BrowserRuntime, targetId: string): Promise<unknown> => {
  const sessionId = active.sessions.get(targetId)
  if (sessionId === undefined) return Promise.resolve()

  return active.connection.send("Page.bringToFront", {}, sessionId).catch(() => undefined)
}
