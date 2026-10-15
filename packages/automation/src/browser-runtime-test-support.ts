import { vi } from "vitest"
import { WebSocket } from "ws"

import type { BrowserRuntime } from "./browser-cdp-engine.js"
import { CdpConnection } from "./browser-cdp.js"
import { initialPointerState } from "./browser-input.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

type CdpParams = Readonly<Record<string, unknown>>

export type FakeCdpSend = (
  method: string,
  params: CdpParams,
  sessionId?: string,
  timeoutMs?: number
) => Promise<unknown>

export interface FakeCdpMethods {
  readonly send?: FakeCdpSend
  readonly sendOnce?: FakeCdpSend
  readonly on?: CdpConnection["on"]
  readonly setSessionRecoveryHandler?: CdpConnection["setSessionRecoveryHandler"]
  readonly close?: () => Promise<void>
}

export const fakeCdpConnection = (
  methods: FakeCdpMethods = {}
): { readonly connection: CdpConnection; readonly disconnect: () => void } => {
  const closeListeners: Array<() => void> = []
  let readyState: number = WebSocket.OPEN
  const closeSocket = () => {
    readyState = WebSocket.CLOSED
    for (const listener of closeListeners.splice(0)) listener()
  }
  const connection = CdpConnection.fromSocket({
    get readyState() {
      return readyState
    },
    on: () => undefined,
    once: (_event: "close", listener: () => void) => {
      closeListeners.push(listener)
    },
    send: () => undefined,
    close: closeSocket,
    terminate: closeSocket
  })
  const closeConnection = connection.close.bind(connection)
  const disconnect = () => {
    void closeConnection()
  }
  const { send, sendOnce, on, setSessionRecoveryHandler, close } = methods
  if (send !== undefined)
    vi.spyOn(connection, "send").mockImplementation(async (method, params = {}, ...rest) =>
      send(method, params, ...rest)
    )
  if (sendOnce !== undefined)
    vi.spyOn(connection, "sendOnce").mockImplementation(async (method, params = {}, ...rest) =>
      sendOnce(method, params, ...rest)
    )
  if (on !== undefined) vi.spyOn(connection, "on").mockImplementation(on)
  if (setSessionRecoveryHandler !== undefined)
    vi.spyOn(connection, "setSessionRecoveryHandler").mockImplementation(setSessionRecoveryHandler)
  if (close !== undefined) vi.spyOn(connection, "close").mockImplementation(close)
  return { connection, disconnect }
}

export const fakeBrowserRuntime = (overrides: Partial<BrowserRuntime> = {}): BrowserRuntime => ({
  connection: fakeCdpConnection().connection,
  processHandle: undefined,
  owned: false,
  sessions: new Map(),
  staleSessions: new Map(),
  snapshots: new Map(),
  eventLog: [],
  logs: new Map(),
  dialogs: new Map(),
  fileChoosers: new Map(),
  downloads: new Map(),
  eventDisposers: [],
  eventSequence: 0,
  tabOrder: [],
  queue: Promise.resolve(),
  ...overrides
})

export const browserToolSessionState = (
  overrides: Partial<BrowserToolSessionState> = {}
): BrowserToolSessionState => ({
  assetInventories: new Map(),
  assetsDir: "",
  downloadsDir: "",
  selectedTargets: new Map(),
  sessionBackends: new Map(),
  sessionDispositions: new Map(),
  sessionTargets: new Map(),
  ...overrides
})

export const fakeBrowserToolInvocation = (
  overrides: Partial<BrowserToolInvocation> = {}
): BrowserToolInvocation => ({
  active: fakeBrowserRuntime(),
  args: {},
  backend: "managed",
  cursor: { move: async () => {}, track: async () => {}, pulse: async () => {} },
  page: {
    target: { targetId: "page", type: "page", title: "", url: "about:blank" },
    sessionId: "page"
  },
  pointer: initialPointerState(),
  toolName: "",
  ...overrides
})
