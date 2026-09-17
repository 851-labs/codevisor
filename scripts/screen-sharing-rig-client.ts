/// HTTP access to the rig processes: the viewer's loopback control port and the host's LAN port,
/// both bearer-token gated. Pure of process state; the CLI passes the local viewer config in.
import type { RigConfiguration } from "./screen-sharing-rig-lib.ts"

/// The request and response bodies below mirror the Swift types in
/// apps/screen-sharing-rig/Sources/ScreenSharingRigKit, which are the schema.

/// What was built and from where, reported by both ends.
export interface RigBuildInfo {
  commit: string
  dirty: boolean
  configuration: string
  builtAt: string
}

/// `GET /status` on either end.
export interface RigStatus {
  role: string
  name: string
  build: RigBuildInfo
  connection: string
  sessionID?: string
  peerName?: string
  peerBuild?: RigBuildInfo
  uptimeSeconds: number
  reconnects: number
  capture?: string
  hud: boolean
  tuning?: string
}

/// Any failing response, and the shape a non-JSON body is wrapped in.
export interface RigErrorBody {
  error: string
}

/// `POST /sample` on the viewer.
export interface RigSampleResponse {
  report: string
  samples: number
  meanPresentedFramesPerSecond?: number
}

/// `POST /control-check` on the viewer. The response counts are absent when the
/// request was denied, in which case there was nothing to deliver.
export interface RigControlCheckResponse {
  granted: boolean
  deniedReason?: string
  clicksSent: number
  keysSent: number
  responsesBefore?: number
  responsesAfter?: number
  revokedReason?: string
}

/// `POST /source` on the host.
export interface RigSourceResponse {
  capture: string
  previous: string
  live: boolean
}

/// `POST /hud` on either end, which echoes the state it settled on.
export interface RigHUDResponse {
  enabled: boolean
}

/// Every field any rig request body carries.
export interface RigRequestBody {
  seconds?: number
  report?: string
  clicks?: number
  keys?: number
  x?: number
  y?: number
  enabled?: boolean
  capture?: string
}

interface RigRequestInit {
  method: string
  headers: Record<string, string>
  signal: AbortSignal
  body?: string
}

export async function http<Result>(
  method: string,
  url: string,
  token: string,
  body?: RigRequestBody
): Promise<Result> {
  const init: RigRequestInit = {
    method,
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(body?.seconds ? (body.seconds + 15) * 1000 : 5000)
  }
  if (body) {
    init.headers["Content-Type"] = "application/json"
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
    // A failing body is the rig's `{ error }` unless it was not JSON at all.
    const failure = parsed as Partial<RigErrorBody>
    throw new Error(`${method} ${url} → ${response.status}: ${failure.error ?? text}`)
  }
  // The caller names the response it asked for; the rig's Swift types are the schema.
  return parsed as Result
}

export interface RigEndpoints {
  token: string
  viewer: string
  host: string
}

export function endpointsFor(config: RigConfiguration): RigEndpoints {
  if (config.role !== "viewer")
    throw new Error("This Mac's rig is not the viewer; status runs from the viewer.")
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
