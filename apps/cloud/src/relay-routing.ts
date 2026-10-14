import {
  encodeCloudFrame,
  encodeRelayEnvelopes,
  parseAppRelayHeader,
  parseMachineOutboundRelayHeader,
  type HubToMachineRelayHeader,
  type RelayFrameHeader,
  type WireRelayEnvelope
} from "@codevisor/api"

export interface RelayHubPort {
  isKnownMachine(machineId: string): boolean
  acceptsMachinePeers(machineId: string): boolean
  deliverToMachine(machineId: string, message: Uint8Array): boolean
  deliverToPeer(peerId: string, message: Uint8Array): boolean
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

export interface MachineRelayEndpoint {
  connectionId: string
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
  const reportGone = (gonePeerId: string): void => {
    hub.send(socket, encodeCloudFrame({ t: "peer-gone", peerId: gonePeerId }))
  }
  const reportedGone = new Set<string>()
  const flush = (): void => {
    if (peerId !== undefined && batch.length > 0) {
      const message = encodeRelayEnvelopes(batch)
      const delivered = hub.deliverToPeer(peerId, message)
      if (!delivered && !reportedGone.has(peerId)) {
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
