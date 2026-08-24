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

export const routeAppRelay = (
  hub: RelayHubPort,
  socket: WebSocket,
  opener: AppRelayOpener,
  envelopes: WireRelayEnvelope[]
): void => {
  let target: WebSocket | undefined
  let targetMachineId: string | undefined
  let batch: { header: HubToMachineRelayHeader; payload: Uint8Array }[] = []
  const flush = (): void => {
    if (target !== undefined && batch.length > 0) {
      if (!hub.send(target, encodeRelayEnvelopes(batch))) {
        // The chosen machine socket is dead but its close event has not
        // fired yet. Report it like any other offline machine; the app
        // closes every channel toward the machine on this error.
        console.warn("relay to machine failed: socket dead before close event", {
          machineId: targetMachineId,
          channelId: batch[0]!.header.frame.channelId
        })
        hub.error(socket, "machine-offline", "machine relay socket failed", {
          machineId: targetMachineId!,
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
    if (machineSocket === undefined) {
      const known = hub.isKnownMachine(header.machineId)
      hub.error(
        socket,
        known ? "machine-offline" : "unknown-machine",
        known ? "machine is not connected" : "no such machine on this account",
        { machineId: header.machineId, channelId: header.frame.channelId }
      )
      continue
    }
    if (machineSocket !== target) {
      flush()
      target = machineSocket
      targetMachineId = header.machineId
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
  let target: WebSocket | undefined
  let targetPeerId: string | undefined
  let batch: { header: unknown; payload: Uint8Array }[] = []
  const flush = (): void => {
    if (target !== undefined && batch.length > 0) {
      if (!hub.send(target, encodeRelayEnvelopes(batch))) {
        // The app socket is dead but its close event has not fired yet:
        // tell the machine now, exactly as if the peer were already gone.
        console.warn("relay to app failed: socket dead before close event", {
          peerId: targetPeerId
        })
        hub.send(socket, encodeCloudFrame({ t: "peer-gone", peerId: targetPeerId! }))
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
    if (peer === undefined) {
      // The app socket vanished; tell the machine so it can drop channels.
      if (!reportedGone.has(header.peerId)) {
        reportedGone.add(header.peerId)
        hub.send(socket, encodeCloudFrame({ t: "peer-gone", peerId: header.peerId }))
      }
      continue
    }
    if (peer !== target) {
      flush()
      target = peer
      targetPeerId = header.peerId
    }
    batch.push({
      header: { machineId: machineDeviceId, frame: header.frame },
      payload: envelope.payload
    })
  }
  flush()
}
