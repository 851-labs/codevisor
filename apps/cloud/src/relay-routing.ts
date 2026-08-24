// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import {
  encodeCloudFrame,
  encodeRelayEnvelopes,
  parseAppRelayHeader,
  parseMachineRelayHeader,
  type HubToMachineRelayHeader,
  type WireRelayEnvelope
} from "@codevisor/api"

/// The hub's relay data path, split from user-hub.ts: routes decoded envelope
/// batches between app and machine sockets, rewriting only the addressing
/// headers — payload ciphertext passes through untouched. Consecutive
/// envelopes for the same destination forward as ONE binary message (senders
/// coalesce for a reason — keep the batching through the hop).

/// What routing needs from the hub; user-hub adapts its socket/registry
/// internals onto this narrow surface.
export interface RelayHubPort {
  /// The live (hello-completed) socket for a machine device id, if any.
  findMachineSocket(machineId: string): WebSocket | undefined
  isKnownMachine(machineId: string): boolean
  /// The app socket for a hub connection id, if it is still around.
  findAppSocket(peerId: string): WebSocket | undefined
  /// send() that reports failure instead of throwing (dead-but-not-closed).
  send(socket: WebSocket, message: string | Uint8Array): boolean
  /// Buffers a message for a machine in its resume grace window. False = no
  /// grace session (or its buffer overflowed and it was abandoned) — report
  /// machine-offline exactly as before resume existed.
  bufferForMachine(machineId: string, message: Uint8Array): boolean
  /// Same for an app connection in grace; false → peer-gone as before.
  bufferForPeer(peerId: string, message: Uint8Array): boolean
  /// Whether an app connection id has a session in its resume grace window.
  appGraceExists(peerId: string): boolean
  error(
    socket: WebSocket,
    code: "machine-offline" | "unknown-machine" | "invalid-frame",
    message: string,
    context?: { machineId?: string; channelId?: string }
  ): void
}

export interface AppRelayOpener {
  connectionId: string
  publicKey?: string
  deviceId?: string
}

type Destination =
  | { kind: "socket"; socket: WebSocket; machineId: string }
  | { kind: "grace"; machineId: string }

const sameDestination = (a: Destination | undefined, b: Destination): boolean =>
  a !== undefined &&
  a.kind === b.kind &&
  a.machineId === b.machineId &&
  (a.kind !== "socket" || b.kind !== "socket" || a.socket === b.socket)

export const routeAppRelay = (
  hub: RelayHubPort,
  socket: WebSocket,
  opener: AppRelayOpener,
  envelopes: WireRelayEnvelope[]
): void => {
  let target: Destination | undefined
  let batch: { header: HubToMachineRelayHeader; payload: Uint8Array }[] = []
  const flush = (): void => {
    if (target !== undefined && batch.length > 0) {
      const message = encodeRelayEnvelopes(batch)
      const delivered =
        target.kind === "socket"
          ? hub.send(target.socket, message)
          : hub.bufferForMachine(target.machineId, message)
      if (!delivered) {
        // Socket dead before its close event, or the grace buffer just
        // overflowed and the session was abandoned. Either way: report it
        // like any other offline machine; the app closes every channel
        // toward the machine on this error.
        console.warn("relay to machine failed", {
          machineId: target.machineId,
          channelId: batch[0]!.header.frame.channelId
        })
        hub.error(socket, "machine-offline", "machine relay delivery failed", {
          machineId: target.machineId,
          channelId: batch[0]!.header.frame.channelId
        })
      }
    }
    batch = []
  }
  for (const envelope of envelopes) {
    const header = parseAppRelayHeader(envelope.header)
    if (header === undefined) {
      hub.error(socket, "invalid-frame", "malformed relay header")
      continue
    }
    const machineSocket = hub.findMachineSocket(header.machineId)
    const destination: Destination | undefined =
      machineSocket !== undefined
        ? { kind: "socket", socket: machineSocket, machineId: header.machineId }
        : hub.isKnownMachine(header.machineId)
          ? { kind: "grace", machineId: header.machineId }
          : undefined
    if (destination === undefined) {
      hub.error(socket, "unknown-machine", "no such machine on this account", {
        machineId: header.machineId,
        channelId: header.frame.channelId
      })
      continue
    }
    if (!sameDestination(target, destination)) {
      flush()
      target = destination
    }
    batch.push({
      header: {
        peerId: opener.connectionId,
        frame: header.frame,
        // Opens carry the opener's identity (key + stable device id) so the
        // machine can complete key agreement and TOFU-pin the key per device.
        ...(header.frame.t === "open" && opener.publicKey !== undefined
          ? { peerPublicKey: opener.publicKey }
          : {}),
        ...(header.frame.t === "open" && opener.deviceId !== undefined
          ? { peerDeviceId: opener.deviceId }
          : {})
      },
      payload: envelope.payload
    })
  }
  flush()
}

/// Mirrors routeAppRelay for the machine→app direction; vanished peers are
/// reported once with peer-gone.
export const routeMachineRelay = (
  hub: RelayHubPort,
  socket: WebSocket,
  machineDeviceId: string,
  envelopes: WireRelayEnvelope[]
): void => {
  let target: { socket: WebSocket | undefined; peerId: string } | undefined
  let batch: { header: unknown; payload: Uint8Array }[] = []
  const reportGone = (peerId: string): void => {
    hub.send(socket, encodeCloudFrame({ t: "peer-gone", peerId }))
  }
  const flush = (): void => {
    if (target !== undefined && batch.length > 0) {
      const message = encodeRelayEnvelopes(batch)
      const delivered =
        target.socket !== undefined
          ? hub.send(target.socket, message)
          : hub.bufferForPeer(target.peerId, message)
      if (!delivered) {
        // Socket dead before its close event, or the grace buffer just
        // overflowed: tell the machine the peer is gone so it drops channels.
        console.warn("relay to app failed", { peerId: target.peerId })
        reportGone(target.peerId)
      }
    }
    batch = []
  }
  const reportedGone = new Set<string>()
  for (const envelope of envelopes) {
    const header = parseMachineRelayHeader(envelope.header)
    if (header === undefined) {
      hub.error(socket, "invalid-frame", "malformed relay header")
      continue
    }
    const peer = hub.findAppSocket(header.peerId)
    if (peer === undefined && !hub.appGraceExists(header.peerId)) {
      // The app vanished with no resumable session; tell the machine once so
      // it drops that peer's channels.
      if (!reportedGone.has(header.peerId)) {
        reportedGone.add(header.peerId)
        reportGone(header.peerId)
      }
      continue
    }
    if (target === undefined || target.peerId !== header.peerId || target.socket !== peer) {
      flush()
      target = { socket: peer, peerId: header.peerId }
    }
    batch.push({
      header: { machineId: machineDeviceId, frame: header.frame },
      payload: envelope.payload
    })
  }
  flush()
}
