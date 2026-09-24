/// HTTP access to the rig processes: the viewer's loopback control port and the host's LAN port,
/// both bearer-token gated. Pure of process state; the CLI passes the local viewer config in.
import type { RigConfiguration } from "./screen-sharing-rig-lib.ts"

/// Response shapes the Swift rig serves. The CLI trusts them the way it trusts rig.json.
export interface RigStatus {
  role: string
  name: string
  build?: { commit: string; dirty: boolean; configuration: string }
  connection: string
  sessionID?: string | null
  reconnects: number
  uptimeSeconds: number
  capture?: string
}

export interface SampleResult {
  samples: number
  meanPresentedFramesPerSecond?: number
  report: string
}

export interface ControlCheckResult {
  granted: boolean
  clicksSent?: number
  keysSent?: number
  responsesBefore?: number
  responsesAfter?: number
  revokedReason?: string
  deniedReason?: string
}

export interface SourceResult {
  previous: string
  capture: string
  live: boolean
}

export interface HudResult {
  enabled: boolean
}

export async function http<T>(
  method: string,
  url: string,
  token: string,
  body?: { seconds?: number; [key: string]: unknown }
): Promise<T> {
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` }
  const init: RequestInit = {
    method,
    headers,
    signal: AbortSignal.timeout(body?.seconds ? (body.seconds + 15) * 1000 : 5000)
  }
  if (body) {
    headers["Content-Type"] = "application/json"
    init.body = JSON.stringify(body)
  }
  const response = await fetch(url, init)
  const text = await response.text()
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = { error: text }
  }
  if (!response.ok) {
    const error =
      typeof parsed === "object" && parsed !== null && "error" in parsed ? parsed.error : undefined
    throw new Error(`${method} ${url} → ${response.status}: ${String(error ?? text)}`)
  }
  return parsed as T
}

export function endpointsFor(config: RigConfiguration): {
  token: string
  viewer: string
  host: string
} {
  if (config.role !== "viewer")
    throw new Error("This Mac's rig is not the viewer; status runs from the viewer.")
  if (!config.peer) throw new Error("The viewer's rig.json has no peer; run install again.")
  return {
    token: config.token,
    viewer: `http://127.0.0.1:${config.controlPort ?? 48732}`,
    host: `http://${config.peer.includes(":") ? config.peer : `${config.peer}:${config.port ?? 48731}`}`
  }
}

export function summarize(status: RigStatus): string {
  const build = status.build
    ? `${status.build.commit.slice(0, 8)}${status.build.dirty ? "*" : ""} ${status.build.configuration}`
    : "?"
  return `${status.role.padEnd(6)} ${status.name} · ${build} · ${status.connection} · session ${status.sessionID ?? "-"} · reconnects ${status.reconnects} · up ${Math.round(status.uptimeSeconds)}s${status.capture ? ` · ${status.capture}` : ""}`
}
