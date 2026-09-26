import {
  encodeCloudFrame,
  encodeRelayEnvelopes,
  parseAppRelayHeader,
  parseMachineOutboundRelayHeader,
  type HubToMachineRelayHeader,
  type RelayFrameHeader,
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
  /// The machine accepts channels from other machines (its last hello
  /// advertised MACHINE_PEERS_FEATURE).
  acceptsMachinePeers(machineId: string): boolean
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

/// A machine socket as a relay endpoint: it answers channels peers opened
/// and — once it advertised MACHINE_PEERS_FEATURE — opens its own channels
/// toward other machines on the account.
export interface MachineRelayEndpoint {
  connectionId: string
  /// Always set on machine sockets (from the authenticated api key).
  deviceId?: string
  publicKey?: string
  peerAware?: boolean
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
  const router = openerRouter(hub, socket, opener, undefined)
  for (const envelope of envelopes) {
    const header = parseAppRelayHeader(envelope.header)
    if (header === undefined) {
      hub.error(socket, "invalid-frame", "malformed relay header")
      continue
    }
    router.push(header.machineId, header.frame, envelope.payload)
  }
  router.flush()
}

/// Opener-side routing shared by apps and machine openers: validates the
/// destination against the account's registry and batches consecutive
/// envelopes per destination. `openerMachineId` is set for machine openers:
/// they may not address themselves, and targets learn the opener's kind.
const openerRouter = (
  hub: RelayHubPort,
  socket: WebSocket,
  opener: AppRelayOpener,
  openerMachineId: string | undefined
): {
  push: (machineId: string, frame: RelayFrameHeader, payload: Uint8Array) => void
  flush: () => void
} => {
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
  const push = (machineId: string, frame: RelayFrameHeader, payload: Uint8Array): void => {
    // The registry holds only this account's machines (one hub per
    // account), so an unknown id — including another account's machine —
    // is refused here. Machine openers may reach only other machines that
    // accept machine peers (older ones would not restrict them to the
    // gateway channel), never themselves.
    const destination: Destination | undefined =
      hub.isKnownMachine(machineId) &&
      (openerMachineId === undefined ||
        (machineId !== openerMachineId && hub.acceptsMachinePeers(machineId)))
        ? { machineId }
        : undefined
    if (destination === undefined) {
      hub.error(socket, "unknown-machine", "no such machine on this account", {
        machineId,
        channelId: frame.channelId
      })
      return
    }
    if (!sameDestination(target, destination)) {
      flush()
      target = destination
    }
    batch.push({
      header: {
        peerId: opener.connectionId,
        frame,
        // Opens carry the opener's identity (key + stable device id) so the
        // machine can complete key agreement and TOFU-pin the key per device.
        ...(frame.t === "open" && opener.publicKey !== undefined
          ? { peerPublicKey: opener.publicKey }
          : {}),
        ...(frame.t === "open" && opener.deviceId !== undefined
          ? { peerDeviceId: opener.deviceId }
          : {}),
        ...(frame.t === "open" && openerMachineId !== undefined
          ? { peerKind: "machine" as const }
          : {})
      },
      payload
    })
  }
  return { push, flush }
}

/// Mirrors routeAppRelay for the machine→opener direction; vanished peers
/// are reported once with peer-gone. Envelopes addressed by `machineId` are
/// channels this machine opens toward another machine on the account —
/// accepted only from peer-aware machines.
export const routeMachineRelay = (
  hub: RelayHubPort,
  socket: WebSocket,
  machine: MachineRelayEndpoint,
  envelopes: WireRelayEnvelope[]
): void => {
  const machineDeviceId = machine.deviceId!
  const opened = openerRouter(hub, socket, machine, machineDeviceId)
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
    const header = parseMachineOutboundRelayHeader(envelope.header)
    if (header === undefined || (header.direction === "open" && machine.peerAware !== true)) {
      hub.error(socket, "invalid-frame", "malformed relay header")
      continue
    }
    if (header.direction === "open") {
      // Keep wire order across the two directions: flush the answer batch
      // before an opened-channel frame and vice versa.
      flush()
      peerId = undefined
      opened.push(header.machineId, header.frame, envelope.payload)
      continue
    }
    opened.flush()
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
  opened.flush()
}
