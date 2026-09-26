import type {
  CloudMachinePresence,
  MachineCallOrigin,
  MachineSummary,
  SyncEntry
} from "@codevisor/api"
import { CodeExecutionToolError } from "@codevisor/automation"
import { GatewayChannelError, type GatewayExchange } from "@codevisor/cloud-client"

import {
  DirectPathError,
  type DirectAnswer,
  type DirectProbe,
  type DirectRoute
} from "./machine-direct.js"

/// This server's view of every machine on the account, and the transport
/// that runs Codevisor gateway calls on them (the sandbox's `machines` API).
///
/// Sources, merged under one stable id per machine (its server id,
/// "machine-<uuid>"):
/// - this machine;
/// - cloud hub presence (machines publish their server id in hello; older
///   servers that don't appear as `cloud:<deviceId>`);
/// - the FleetRoster "machines" sync namespace — direct `{name, url, token}`
///   routes keyed by server id, replicated to every server.
///
/// A call tries the direct route first, then the cloud relay, and falls
/// back only when the earlier path provably never delivered the request.
/// Nothing is retried once a request may have reached the target.

export interface MachineLinkCloud {
  /// This machine's own cloud device id (undefined while not registered).
  readonly deviceId: () => string | undefined
  readonly machines: () => ReadonlyArray<CloudMachinePresence> | undefined
  /// Runs one POST /v1/gateway/invoke exchange over a sealed relay channel;
  /// rejects with GatewayChannelError.
  readonly request: (
    deviceId: string,
    body: string,
    signal?: AbortSignal
  ) => Promise<GatewayExchange>
}

export interface RosterRoute extends DirectRoute {
  /// The machine's stable server id (the roster key).
  readonly id: string
  readonly name?: string
}

export interface MachineLinkOptions {
  readonly self: { readonly id: string; readonly name: () => string; readonly os: string }
  readonly cloud?: MachineLinkCloud
  readonly roster: () => Promise<ReadonlyArray<RosterRoute>>
  /// The direct path (production: postGatewayInvoke) and its reachability
  /// probe (probeDirect), both in machine-direct.ts.
  readonly direct: (route: DirectRoute, body: string, signal?: AbortSignal) => Promise<DirectAnswer>
  readonly probe: (route: DirectRoute) => Promise<DirectProbe>
  readonly now: () => number
}

export interface MachineLink {
  readonly list: () => Promise<ReadonlyArray<MachineSummary>>
  /// Runs gateway `path` with `args` on `machine` (an id, or a
  /// case-insensitive name). Throws CodeExecutionToolError: the target's own
  /// tool error, or code "machine_unavailable" with details
  /// { machineId, name, lastSeen, phase: "before-send" | "in-flight" }.
  readonly invoke: (
    machine: string,
    path: string,
    args: unknown,
    origin: MachineCallOrigin,
    signal?: AbortSignal
  ) => Promise<unknown>
}

export const GATEWAY_INVOKE_PATH = "/v1/gateway/invoke"

/// FleetRoster's replicated namespace (see FleetRoster.swift): one entry per
/// direct remote, keyed by its stable server id, valued { name, url, token }.
export const FLEET_ROSTER_NAMESPACE = "machines"

/// Live roster routes from the namespace's replica (tombstones and malformed
/// entries skipped).
export const rosterRoutes = (entries: ReadonlyArray<SyncEntry>): RosterRoute[] =>
  entries.flatMap((entry) => {
    const value = entry.value
    if (entry.deleted === true || !isRecord(value) || typeof value.url !== "string") return []
    return [
      {
        id: entry.key,
        url: value.url,
        ...(typeof value.name === "string" ? { name: value.name } : {}),
        ...(typeof value.token === "string" ? { token: value.token } : {})
      }
    ]
  })

/// A probe answer stays fresh this long, so listing machines repeatedly
/// does not hammer unreachable routes.
const PROBE_TTL_MS = 15_000

interface Target {
  readonly id: string
  readonly name: string
  readonly os?: string
  readonly isCurrent: boolean
  readonly direct?: DirectRoute
  readonly cloud?: CloudMachinePresence
}

const toolError = (
  message: string,
  code?: string,
  details?: Record<string, unknown>
): CodeExecutionToolError =>
  new CodeExecutionToolError(message, {
    ...(code === undefined ? {} : { code }),
    ...(details === undefined ? {} : { details })
  })

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const parseJson = (text: string): unknown => {
  try {
    return JSON.parse(text) as unknown
  } catch {
    return undefined
  }
}

/// "just now", "3m ago", "5h ago", "2d ago".
export const relativeAge = (iso: string, now: number): string => {
  const seconds = Math.max(0, Math.round((now - Date.parse(iso)) / 1000))
  if (seconds < 60) return "just now"
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 48) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

/// Why a path could not deliver the request: the target is unreachable on
/// it, or reachable but running a version without cross-machine calls.
type PathMiss = "unreachable" | "unsupported"

export const makeMachineLink = (options: MachineLinkOptions): MachineLink => {
  const { now, direct, probe } = options
  /// Last successful contact per direct machine id (probe or call), and
  /// the latest probe verdict with its time.
  const lastContact = new Map<string, number>()
  const probes = new Map<string, DirectProbe & { readonly at: number }>()

  const contacted = (id: string): void => {
    lastContact.set(id, now())
  }

  const targets = async (): Promise<Target[]> => {
    const selfDeviceId = options.cloud?.deviceId()
    const byId = new Map<string, Target>()
    byId.set(options.self.id, {
      id: options.self.id,
      name: options.self.name(),
      os: options.self.os,
      isCurrent: true
    })
    for (const presence of options.cloud?.machines() ?? []) {
      if (presence.deviceId === selfDeviceId || presence.serverId === options.self.id) continue
      const id = presence.serverId ?? `cloud:${presence.deviceId}`
      byId.set(id, {
        id,
        name: presence.name,
        ...(presence.os === undefined ? {} : { os: presence.os }),
        isCurrent: false,
        cloud: presence
      })
    }
    for (const route of await options.roster()) {
      if (route.id === options.self.id) continue
      const known = byId.get(route.id)
      byId.set(route.id, {
        id: route.id,
        // The machine's own (hub) name wins over a client-chosen label.
        name: known?.name ?? route.name ?? route.url,
        ...(known?.os === undefined ? {} : { os: known.os }),
        isCurrent: false,
        ...(known?.cloud === undefined ? {} : { cloud: known.cloud }),
        direct: { url: route.url, ...(route.token === undefined ? {} : { token: route.token }) }
      })
    }
    return [...byId.values()]
  }

  const lastSeenOf = (target: Target): string | undefined => {
    const contact = lastContact.get(target.id)
    const cloudSeen = target.cloud === undefined ? undefined : Date.parse(target.cloud.lastSeenAt)
    const latest = Math.max(contact ?? -Infinity, cloudSeen ?? -Infinity)
    return Number.isFinite(latest) ? new Date(latest).toISOString() : undefined
  }

  const directOnline = async (target: Target, route: DirectRoute): Promise<boolean> => {
    const cached = probes.get(target.id)
    if (cached !== undefined && now() - cached.at < PROBE_TTL_MS) return cached.online
    const answer = await probe(route)
    probes.set(target.id, { ...answer, at: now() })
    if (answer.online) contacted(target.id)
    return answer.online
  }

  const summarize = async (target: Target): Promise<MachineSummary> => {
    const online =
      target.isCurrent ||
      target.cloud?.online === true ||
      (target.direct !== undefined && (await directOnline(target, target.direct)))
    const lastSeen = target.isCurrent ? undefined : lastSeenOf(target)
    // A machine's own discovery answer beats a registry copy of its platform.
    const os = probes.get(target.id)?.os ?? target.os
    return {
      id: target.id,
      name: target.name,
      ...(os === undefined ? {} : { os }),
      online,
      ...(lastSeen === undefined ? {} : { lastSeen }),
      isCurrent: target.isCurrent
    }
  }

  const unavailable = (
    target: { readonly id: string; readonly name: string },
    phase: "before-send" | "in-flight",
    message: string,
    lastSeen: string | undefined
  ): CodeExecutionToolError =>
    toolError(message, "machine_unavailable", {
      machineId: target.id,
      name: target.name,
      lastSeen: lastSeen ?? null,
      phase
    })

  const lostMidCall = (target: Target): CodeExecutionToolError =>
    unavailable(
      target,
      "in-flight",
      `Lost connection to ${target.name} mid-call; the tool may or may not have completed`,
      lastSeenOf(target)
    )

  /// The target's answer: its result, or its own tool error re-thrown with
  /// the same message/code/details.
  const interpret = (target: Target, answer: DirectAnswer): unknown => {
    const parsed = parseJson(answer.body)
    if (answer.status >= 200 && answer.status < 300 && isRecord(parsed) && "result" in parsed) {
      return parsed.result
    }
    if (isRecord(parsed) && isRecord(parsed.error) && typeof parsed.error.message === "string") {
      throw toolError(
        parsed.error.message,
        typeof parsed.error.code === "string" ? parsed.error.code : undefined,
        isRecord(parsed.error.details) ? parsed.error.details : undefined
      )
    }
    const detail = isRecord(parsed) && typeof parsed.error === "string" ? `: ${parsed.error}` : ""
    throw toolError(`${target.name} answered HTTP ${answer.status}${detail}`)
  }

  const viaDirect = async (
    target: Target,
    route: DirectRoute,
    body: string,
    signal: AbortSignal | undefined
  ): Promise<DirectAnswer | PathMiss> => {
    let answer: DirectAnswer
    try {
      answer = await direct(route, body, signal)
    } catch (cause) {
      if (!(cause instanceof DirectPathError)) throw cause
      if (cause.phase === "in-flight") throw lostMidCall(target)
      probes.set(target.id, { online: false, at: now() })
      return "unreachable"
    }
    contacted(target.id)
    // A rejected token never ran anything; a 404 is a server predating the
    // route. Both leave the relay worth trying.
    if (answer.status === 401 || answer.status === 403) return "unreachable"
    // (The route itself never answers 404.)
    if (answer.status === 404) return "unsupported"
    return answer
  }

  const viaCloud = async (
    target: Target,
    cloud: MachineLinkCloud,
    presence: CloudMachinePresence,
    body: string,
    signal: AbortSignal | undefined
  ): Promise<DirectAnswer | PathMiss> => {
    try {
      return await cloud.request(presence.deviceId, body, signal)
    } catch (cause) {
      if (!(cause instanceof GatewayChannelError)) throw cause
      if (cause.phase === "in-flight") throw lostMidCall(target)
      return cause.closeReason === "unsupported" ? "unsupported" : "unreachable"
    }
  }

  return {
    list: async () => Promise.all((await targets()).map(summarize)),
    invoke: async (machine, path, args, origin, signal) => {
      const all = await targets()
      const lowered = machine.toLowerCase()
      const target =
        all.find((candidate) => candidate.id === machine) ??
        all.find((candidate) => candidate.name.toLowerCase() === lowered)
      if (target === undefined) {
        throw unavailable(
          { id: machine, name: machine },
          "before-send",
          `No machine "${machine}" on this account`,
          undefined
        )
      }
      if (target.isCurrent) {
        throw toolError(`${target.name} is the current machine; call its tools directly`)
      }
      const body = JSON.stringify({ path, args, origin })
      const misses: PathMiss[] = []
      if (target.direct !== undefined) {
        const answer = await viaDirect(target, target.direct, body, signal)
        if (typeof answer !== "string") return interpret(target, answer)
        misses.push(answer)
      }
      if (options.cloud !== undefined && target.cloud !== undefined) {
        const answer = await viaCloud(target, options.cloud, target.cloud, body, signal)
        if (typeof answer !== "string") return interpret(target, answer)
        misses.push(answer)
      }
      const lastSeen = lastSeenOf(target)
      if (misses.includes("unsupported")) {
        throw unavailable(
          target,
          "before-send",
          `${target.name} runs a Codevisor version that can't take calls from other machines; update it`,
          lastSeen
        )
      }
      const since = lastSeen === undefined ? "" : ` (last seen ${relativeAge(lastSeen, now())})`
      throw unavailable(target, "before-send", `${target.name} is offline${since}`, lastSeen)
    }
  }
}
