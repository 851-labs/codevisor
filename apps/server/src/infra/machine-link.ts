import type { CloudMachinePresence, MachineCallOrigin, MachineSummary } from "@codevisor/api"
import { CodeExecutionToolError } from "@codevisor/automation"
import { GatewayChannelError, type GatewayExchange } from "@codevisor/cloud-client"

/// This server's view of every machine on the account, and the transport
/// that runs Codevisor gateway calls on them (the sandbox's `machines` API).
///
/// Sources, merged under one stable id per machine (its server id,
/// "machine-<uuid>"):
/// - this machine;
/// - cloud hub presence (machines publish their server id in hello; older
///   servers that don't appear as `cloud:<deviceId>`).
///
/// A call runs over the cloud relay. Nothing is retried once a request may
/// have reached the target.

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

export interface MachineLinkOptions {
  readonly self: { readonly id: string; readonly name: () => string; readonly os: string }
  readonly cloud: MachineLinkCloud
  readonly now: () => number
}

export interface MachineLink {
  readonly list: () => Promise<ReadonlyArray<MachineSummary>>
  /// Finds a machine by id or case-insensitive name (ids win): "self" for
  /// this machine, its cloud presence for another, undefined when unknown.
  readonly resolve: (
    machine: string
  ) =>
    | "self"
    | { readonly id: string; readonly name: string; readonly deviceId: string }
    | undefined
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

/// Another machine on the account, as the hub reports it.
interface Peer {
  readonly id: string
  readonly name: string
  readonly presence: CloudMachinePresence
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

/// Why the relay could not deliver the request: the target is unreachable,
/// or reachable but running a version without cross-machine calls.
type PathMiss = "unreachable" | "unsupported"

const summarize = (peer: Peer): MachineSummary => ({
  id: peer.id,
  name: peer.name,
  ...(peer.presence.os === undefined ? {} : { os: peer.presence.os }),
  online: peer.presence.online,
  lastSeen: peer.presence.lastSeenAt,
  isCurrent: false,
  ...(peer.presence.addedBy === undefined ? {} : { addedBy: peer.presence.addedBy.name })
})

export const makeMachineLink = (options: MachineLinkOptions): MachineLink => {
  const { cloud, now, self } = options

  const peers = (): Peer[] => {
    const selfDeviceId = cloud.deviceId()
    const byId = new Map<string, Peer>()
    for (const presence of cloud.machines() ?? []) {
      if (presence.deviceId === selfDeviceId || presence.serverId === self.id) continue
      const id = presence.serverId ?? `cloud:${presence.deviceId}`
      byId.set(id, { id, name: presence.name, presence })
    }
    return [...byId.values()]
  }

  const find = (machine: string): "self" | Peer | undefined => {
    const lowered = machine.toLowerCase()
    const all = peers()
    // Ids win over names; this machine is matched like any other.
    if (machine === self.id) return "self"
    const byId = all.find((candidate) => candidate.id === machine)
    if (byId !== undefined) return byId
    if (self.name().toLowerCase() === lowered) return "self"
    return all.find((candidate) => candidate.name.toLowerCase() === lowered)
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

  /// The target's answer: its result, or its own tool error re-thrown with
  /// the same message/code/details.
  const interpret = (peer: Peer, answer: GatewayExchange): unknown => {
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
    throw toolError(`${peer.name} answered HTTP ${answer.status}${detail}`)
  }

  /// One relay exchange, or why it provably never reached the target.
  /// Nothing is retried once the request may have reached it.
  const viaCloud = async (
    peer: Peer,
    body: string,
    signal: AbortSignal | undefined
  ): Promise<GatewayExchange | PathMiss> => {
    try {
      return await cloud.request(peer.presence.deviceId, body, signal)
    } catch (cause) {
      if (!(cause instanceof GatewayChannelError)) throw cause
      if (cause.phase === "in-flight") {
        throw unavailable(
          peer,
          "in-flight",
          `Lost connection to ${peer.name} mid-call; the tool may or may not have completed`,
          peer.presence.lastSeenAt
        )
      }
      return cause.closeReason === "unsupported" ? "unsupported" : "unreachable"
    }
  }

  return {
    list: () =>
      Promise.resolve([
        { id: self.id, name: self.name(), os: self.os, online: true, isCurrent: true },
        ...peers().map(summarize)
      ]),
    resolve: (machine) => {
      const found = find(machine)
      if (found === undefined || found === "self") return found
      return { id: found.id, name: found.name, deviceId: found.presence.deviceId }
    },
    invoke: async (machine, path, args, origin, signal) => {
      const peer = find(machine)
      if (peer === "self") {
        throw toolError(`${self.name()} is the current machine; call its tools directly`)
      }
      if (peer === undefined) {
        throw unavailable(
          { id: machine, name: machine },
          "before-send",
          `No machine "${machine}" on this account`,
          undefined
        )
      }
      const answer = await viaCloud(peer, JSON.stringify({ path, args, origin }), signal)
      if (typeof answer !== "string") return interpret(peer, answer)
      const lastSeen = peer.presence.lastSeenAt
      if (answer === "unsupported") {
        throw unavailable(
          peer,
          "before-send",
          `${peer.name} runs a Codevisor version that can't take calls from other machines; update it`,
          lastSeen
        )
      }
      throw unavailable(
        peer,
        "before-send",
        `${peer.name} is offline (last seen ${relativeAge(lastSeen, now())})`,
        lastSeen
      )
    }
  }
}
