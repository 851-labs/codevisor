import { invoke, isTauri } from "@tauri-apps/api/core"
import { listen, type UnlistenFn } from "@tauri-apps/api/event"

// Where the app finds its herdman server. Inside Tauri the Rust side owns the
// server lifecycle and hands us the loopback endpoint; in a plain browser the
// endpoint comes from env/localStorage, defaulting to same-origin (the vite
// dev proxy forwards /v1 to the dev server).
export interface ServerConfig {
  baseUrl: string
  wsBaseUrl: string
  token?: string
}

// Mirrors the Rust ServerState enum (serde tag = "state", content = "detail").
export type ServerLifecycleState =
  | { state: "idle" | "starting" | "alreadyRunning" | "started" }
  | { state: "unavailable"; detail: string }

interface TauriServerConfig {
  baseUrl: string
  token: string | null
  state: ServerLifecycleState
}

const STATE_EVENT = "herdman://server-state"

function toWebSocketUrl(httpUrl: string): string {
  return httpUrl.replace(/^http:/, "ws:").replace(/^https:/, "wss:")
}

function sameOriginWsBase(): string {
  const scheme = window.location.protocol === "https:" ? "wss" : "ws"
  return `${scheme}://${window.location.host}`
}

function readBrowserOverride(key: string): string | undefined {
  try {
    return window.localStorage.getItem(key) ?? undefined
  } catch {
    return undefined
  }
}

export async function resolveServerConfig(): Promise<ServerConfig> {
  if (isTauri()) {
    const config = await invoke<TauriServerConfig>("get_server_config")
    return {
      baseUrl: config.baseUrl,
      wsBaseUrl: toWebSocketUrl(config.baseUrl),
      token: config.token ?? undefined
    }
  }
  const explicit =
    (import.meta.env.VITE_HERDMAN_SERVER_URL as string | undefined) ??
    readBrowserOverride("herdman.serverUrl") ??
    ""
  const baseUrl = explicit.replace(/\/+$/, "")
  const token =
    (import.meta.env.VITE_HERDMAN_SERVER_TOKEN as string | undefined) ??
    readBrowserOverride("herdman.serverToken")
  return {
    baseUrl,
    wsBaseUrl: baseUrl === "" ? sameOriginWsBase() : toWebSocketUrl(baseUrl),
    token
  }
}

export function getServerLifecycleState(): Promise<ServerLifecycleState> {
  if (!isTauri()) return Promise.resolve({ state: "alreadyRunning" })
  return invoke<ServerLifecycleState>("server_status")
}

export function retryServer(): Promise<void> {
  if (!isTauri()) return Promise.resolve()
  return invoke("retry_server")
}

// Subscribes to the Rust-side lifecycle events. Returns an unsubscribe
// function; a no-op outside Tauri (the browser assumes a running server).
export function subscribeServerLifecycle(
  onState: (state: ServerLifecycleState) => void
): () => void {
  if (!isTauri()) return () => {}
  let unlisten: UnlistenFn | undefined
  let cancelled = false
  void listen<ServerLifecycleState>(STATE_EVENT, (event) => {
    onState(event.payload)
  }).then((stop) => {
    if (cancelled) stop()
    else unlisten = stop
  })
  return () => {
    cancelled = true
    unlisten?.()
  }
}
