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
  isKnownMachine(machineId: string): boolean
  /// Tries every eligible live socket, retiring failures, then buffers during
  /// resume grace. False means the destination is definitively unavailable.
  deliverToMachine(machineId: string, message: Uint8Array): boolean
  deliverToPeer(peerId: string, message: Uint8Array): boolean
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

type Destination = { machineId: string }

const sameDestination = (a: Destination | undefined, b: Destination): boolean =>
  a !== undefined && a.machineId === b.machineId

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
      const delivered = hub.deliverToMachine(target.machineId, message)
      if (!delivered) {
        // This error is scoped to the attempted channel. A global offline
        // transition is broadcast only when the resume grace expires.
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
    const destination: Destination | undefined = hub.isKnownMachine(header.machineId)
      ? { machineId: header.machineId }
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
  let peerId: string | undefined
  let batch: { header: unknown; payload: Uint8Array }[] = []
  const reportGone = (peerId: string): void => {
    hub.send(socket, encodeCloudFrame({ t: "peer-gone", peerId }))
  }
  const reportedGone = new Set<string>()
  const flush = (): void => {
    if (peerId !== undefined && batch.length > 0) {
      const message = encodeRelayEnvelopes(batch)
      const delivered = hub.deliverToPeer(peerId, message)
      if (!delivered && !reportedGone.has(peerId)) {
        // Socket dead before its close event, or the grace buffer just
        // overflowed: tell the machine the peer is gone so it drops channels.
        reportedGone.add(peerId)
        console.warn("relay to app failed", { peerId })
        reportGone(peerId)
      }
    }
    batch = []
  }
  for (const envelope of envelopes) {
    const header = parseMachineRelayHeader(envelope.header)
    if (header === undefined) {
      hub.error(socket, "invalid-frame", "malformed relay header")
      continue
    }
    if (peerId !== header.peerId) {
      flush()
      peerId = header.peerId
    }
    batch.push({
      header: { machineId: machineDeviceId, frame: header.frame },
      payload: envelope.payload
    })
  }
  flush()
}
