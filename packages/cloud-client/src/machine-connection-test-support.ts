import {
  CLOUD_PROTOCOL_VERSION,
  decodeMachineToHub,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes
} from "@codevisor/api"
import type {
  HubToMachine,
  MachineRelayHeader,
  MachineToHub,
  RelayFrameHeader
} from "@codevisor/api"
import { generateDeviceKeyPair, openChannel, sealJson } from "@codevisor/cloud-crypto"
import { CloudMachineConnection } from "./index.js"
import type {
  CloudSocket,
  IncomingChannel,
  MachineDisconnectReason,
  MachineConnectionState,
  PeerKeyPinStore
} from "./index.js"

/// Fake hub socket, scripted timers, and connection harness for the machine
/// connection tests.

export interface SentEnvelope {
  header: MachineRelayHeader
  payload: Uint8Array
}

export class FakeSocket implements CloudSocket {
  /// JSON control frames, in order.
  sent: MachineToHub[] = []
  /// Binary relay messages, one entry per WebSocket message (each may carry
  /// several envelopes when the sender coalesces).
  relayMessages: SentEnvelope[][] = []
  closed: { code?: number; reason?: string } | undefined
  terminated = false
  sendError: Error | undefined
  onSend: ((frame: MachineToHub) => void) | undefined
  onopen: (() => void) | null = null
  onmessage: ((data: string | Uint8Array) => void) | null = null
  onclose: ((code: number) => void) | null = null

  send(data: string | Uint8Array): void {
    if (this.sendError !== undefined) throw this.sendError
    if (typeof data === "string") {
      const frame = decodeMachineToHub(data)
      this.sent.push(frame)
      this.onSend?.(frame)
      return
    }
    this.relayMessages.push(
      decodeRelayEnvelopes(data).map((envelope) => ({
        header: envelope.header as MachineRelayHeader,
        payload: new Uint8Array(envelope.payload)
      }))
    )
  }

  close(code?: number, reason?: string): void {
    this.closed = code !== undefined ? { code, ...(reason !== undefined ? { reason } : {}) } : {}
  }

  terminate(): void {
    this.terminated = true
  }

  receive(frame: HubToMachine): void {
    this.onmessage?.(encodeCloudFrame(frame))
  }

  /// Delivers one hub→machine relay envelope as its own binary message.
  receiveRelay(header: Record<string, unknown>, payload: Uint8Array = new Uint8Array(0)): void {
    this.onmessage?.(encodeRelayEnvelopes([{ header, payload }]))
  }

  /// Every sent relay envelope across all messages, in order.
  get sentRelay(): SentEnvelope[] {
    return this.relayMessages.flat()
  }

  relayFrames(): RelayFrameHeader[] {
    return this.sentRelay.map((envelope) => envelope.header.frame)
  }

  closeFrames(): Extract<RelayFrameHeader, { t: "close" }>[] {
    return this.relayFrames().filter(
      (frame): frame is Extract<RelayFrameHeader, { t: "close" }> => frame.t === "close"
    )
  }

  lastClose(): Extract<RelayFrameHeader, { t: "close" }> {
    const frame = this.closeFrames().at(-1)
    if (frame === undefined) throw new Error("no close frame sent")
    return frame
  }
}

export interface ScheduledTimeout {
  delayMs: number
  cancelled: boolean
  fired: boolean
  run(): void
  invoke(): void
}

export const machineKeys = generateDeviceKeyPair()

export const credentials = {
  serverUrl: "https://cloud.example",
  deviceId: "machine-1",
  publicKey: machineKeys.publicKey,
  secretKey: machineKeys.secretKey,
  apiKey: "api-key"
}

export interface Harness {
  connection: CloudMachineConnection
  sockets: FakeSocket[]
  urls: string[]
  headers: Record<string, string>[]
  states: MachineConnectionState[]
  reconnects: { callback: () => void; delayMs: number }[]
  timeouts: ScheduledTimeout[]
  disconnects: MachineDisconnectReason[]
  channels: IncomingChannel[]
  welcomes: { resumed: boolean; replayedFrames: number }[]
}

export const harness = (
  overrides: {
    handlers?: Record<string, (channel: IncomingChannel) => void>
    device?: { name: string; os?: string; appVersion?: string }
    peerKeyPins?: PeerKeyPinStore
    onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
    relayCoalesceMs?: number
    compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
    decompressPayload?: (bytes: Uint8Array) => Uint8Array
    now?: () => number
  } = {}
): Harness => {
  const sockets: FakeSocket[] = []
  const urls: string[] = []
  const headers: Record<string, string>[] = []
  const states: MachineConnectionState[] = []
  const reconnects: { callback: () => void; delayMs: number }[] = []
  const timeouts: ScheduledTimeout[] = []
  const disconnects: MachineDisconnectReason[] = []
  const channels: IncomingChannel[] = []
  const welcomes: { resumed: boolean; replayedFrames: number }[] = []
  const connection = new CloudMachineConnection({
    credentials,
    device: overrides.device ?? { name: "vps", os: "linux", appVersion: "1.0.0" },
    socketFactory: (url, requestHeaders) => {
      urls.push(url)
      headers.push(requestHeaders)
      const socket = new FakeSocket()
      sockets.push(socket)
      return socket
    },
    channelHandlers: overrides.handlers ?? { echo: (channel) => channels.push(channel) },
    ...(overrides.peerKeyPins === undefined ? {} : { peerKeyPins: overrides.peerKeyPins }),
    ...(overrides.onPeerKeyMismatch === undefined
      ? {}
      : { onPeerKeyMismatch: overrides.onPeerKeyMismatch }),
    ...(overrides.relayCoalesceMs === undefined
      ? {}
      : { relayCoalesceMs: overrides.relayCoalesceMs }),
    ...(overrides.compressPayload === undefined
      ? {}
      : { compressPayload: overrides.compressPayload }),
    ...(overrides.decompressPayload === undefined
      ? {}
      : { decompressPayload: overrides.decompressPayload }),
    onStateChange: (state) => states.push(state),
    onDisconnect: (reason) => disconnects.push(reason),
    onWelcome: (info) => welcomes.push(info),
    ...(overrides.now === undefined ? {} : { now: overrides.now }),
    scheduleReconnect: (callback, delayMs) => reconnects.push({ callback, delayMs }),
    scheduleTimeout: (callback, delayMs) => {
      const timeout: ScheduledTimeout = {
        delayMs,
        cancelled: false,
        fired: false,
        run: () => {
          if (timeout.cancelled || timeout.fired) return
          timeout.invoke()
        },
        invoke: () => {
          if (timeout.fired) return
          timeout.fired = true
          callback()
        }
      }
      timeouts.push(timeout)
      return () => {
        timeout.cancelled = true
      }
    },
    random: () => 0.5
  })
  return {
    connection,
    sockets,
    urls,
    headers,
    states,
    reconnects,
    timeouts,
    disconnects,
    channels,
    welcomes
  }
}

export const activeTimeout = (h: Harness, delayMs: number): ScheduledTimeout => {
  const timeout = h.timeouts.find(
    (candidate) => candidate.delayMs === delayMs && !candidate.cancelled && !candidate.fired
  )
  if (timeout === undefined) throw new Error(`No active ${delayMs}ms timeout`)
  return timeout
}

export const connect = (h: Harness): FakeSocket => {
  h.connection.start()
  const socket = h.sockets.at(-1)!
  socket.onopen?.()
  socket.receive({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "conn-m" })
  return socket
}

/// Simulates the app side of a channel open, returning the opener's cipher.
export const openEcho = (
  socket: FakeSocket,
  peerId: string,
  channelId: string,
  params: unknown = { hello: true },
  identity: {
    appKeys?: ReturnType<typeof generateDeviceKeyPair>
    peerDeviceId?: string
    compress?: boolean
  } = {}
) => {
  const appKeys = identity.appKeys ?? generateDeviceKeyPair()
  const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
  socket.receiveRelay(
    {
      peerId,
      peerPublicKey: appKeys.publicKey,
      ...(identity.peerDeviceId === undefined ? {} : { peerDeviceId: identity.peerDeviceId }),
      frame: { t: "open", channelId, seq: 0, ephemeralKey: opened.ephemeralPublicKey }
    },
    sealJson(opened.cipher, channelId, "opener-to-responder", 0, {
      channelType: "echo",
      params,
      ...(identity.compress === true ? { compress: true } : {})
    })
  )
  return { appKeys, opened }
}
