import {
  CLOUD_PROTOCOL_VERSION,
  GATEWAY_CHANNEL_TYPE,
  type CloudMachinePresence
} from "@codevisor/api"
import { generateDeviceKeyPair } from "@codevisor/cloud-crypto"

import {
  GatewayChannelError,
  gatewayChannelHandler,
  makePeerKeyPinStore,
  requestOverGatewayChannel,
  type IncomingChannel
} from "./index.js"
import {
  harness,
  type FakeSocket,
  type Harness,
  type SentEnvelope
} from "./machine-connection-test-support.js"

export interface Peer {
  h: Harness
  socket: FakeSocket
  deviceId: string
  keys: ReturnType<typeof generateDeviceKeyPair>
  connectionId: string
}

export const presence = (peer: Peer, online = true): CloudMachinePresence => ({
  deviceId: peer.deviceId,
  name: peer.deviceId,
  publicKey: peer.keys.publicKey,
  online,
  lastSeenAt: "2100-01-01T00:00:00.000Z",
  machinePeers: true
})

export const makePeer = (
  deviceId: string,
  options: {
    handle?: Parameters<typeof gatewayChannelHandler>[0]
    pins?: ReturnType<typeof makePeerKeyPinStore>
    handlers?: Record<string, (channel: IncomingChannel) => void>
  } = {}
): Peer => {
  const keys = generateDeviceKeyPair()
  const h = harness({
    credentials: {
      serverUrl: "https://cloud.example",
      deviceId,
      publicKey: keys.publicKey,
      secretKey: keys.secretKey,
      apiKey: `key-${deviceId}`
    },
    device: { name: deviceId, serverId: `machine-${deviceId}` },
    handlers: options.handlers ?? {
      [GATEWAY_CHANNEL_TYPE]: gatewayChannelHandler(
        options.handle ?? (async (request) => ({ status: 200, body: request.toUpperCase() })),
        () => undefined
      )
    },
    ...(options.pins === undefined ? {} : { peerKeyPins: options.pins })
  })
  h.connection.start()
  const socket = h.sockets.at(-1)!
  socket.onopen?.()
  return { h, socket, deviceId, keys, connectionId: `conn-${deviceId}` }
}

export const welcome = (peer: Peer, machines?: CloudMachinePresence[]): void =>
  peer.socket.receive({
    t: "welcome",
    protocol: CLOUD_PROTOCOL_VERSION,
    connectionId: peer.connectionId,
    ...(machines === undefined ? {} : { machines })
  })

export const pair = (
  options: { a?: Parameters<typeof makePeer>[1]; b?: Parameters<typeof makePeer>[1] } = {}
) => {
  const a = makePeer("a", options.a)
  const b = makePeer("b", options.b)
  const peers = [a, b]
  const queue: (() => void)[] = []
  const hub = {
    holding: false,
    flush: (): void => {
      while (!hub.holding && queue.length > 0) queue.shift()!()
    }
  }
  for (const sender of peers) {
    sender.socket.onRelay = (envelopes: SentEnvelope[]) => {
      for (const { header, payload } of envelopes) {
        const deliver = (): void => {
          if (header.direction === "open") {
            const target = peers.find((peer) => peer.deviceId === header.machineId)!
            target.socket.receiveRelay(
              {
                peerId: sender.connectionId,
                frame: header.frame,
                ...(header.frame.t === "open"
                  ? {
                      peerKind: "machine",
                      peerDeviceId: sender.deviceId,
                      peerPublicKey: sender.keys.publicKey
                    }
                  : {})
              },
              payload
            )
            return
          }
          const opener = peers.find((peer) => peer.connectionId === header.peerId)!
          opener.socket.receiveRelay({ machineId: sender.deviceId, frame: header.frame }, payload)
        }
        queue.push(deliver)
        queueMicrotask(hub.flush)
      }
    }
  }
  welcome(a, [presence(a), presence(b)])
  welcome(b, [presence(a), presence(b)])
  return { a, b, hub }
}

export const timers = () => {
  const pending: { callback: () => void; delayMs: number; cancelled: boolean }[] = []
  return {
    pending,
    scheduleTimeout: (callback: () => void, delayMs: number) => {
      const timer = { callback, delayMs, cancelled: false }
      pending.push(timer)
      return () => {
        timer.cancelled = true
      }
    }
  }
}

export const gatewayRequest = (
  from: Peer,
  to: Peer,
  body: string,
  options: Parameters<typeof requestOverGatewayChannel>[2] = {}
) =>
  requestOverGatewayChannel(
    () => from.h.connection.openChannel(to.deviceId, GATEWAY_CHANNEL_TYPE),
    body,
    { scheduleTimeout: timers().scheduleTimeout, ...options }
  )

export const failure = async (promise: Promise<unknown>): Promise<GatewayChannelError> => {
  const error = await promise.then(
    () => undefined,
    (cause: unknown) => cause
  )
  if (!(error instanceof GatewayChannelError)) {
    throw new Error(`expected a GatewayChannelError, got ${String(error)}`)
  }
  return error
}
