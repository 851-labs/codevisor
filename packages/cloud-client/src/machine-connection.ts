import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToMachine,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  parseHubToMachineRelayHeader,
  type RelayFrameHeader,
  type WireRelayEnvelope
} from "@codevisor/api"
import { ChannelReceiver } from "./channel-receiver.js"
import type { ChannelHandler } from "./incoming-channel.js"
import type { MachineCredentials } from "./login.js"
import {
  RelayOutbox,
  reconnectDelayMs,
  type CancelTimeout,
  type CloudSocket,
  type MachineConnectionState,
  type MachineDisconnectReason,
  type SocketFactory
} from "./machine-socket.js"
import type { PeerKeyPinStore } from "./peer-pins.js"

export interface MachineConnectionOptions {
  credentials: MachineCredentials
  device: { name: string; os?: string; appVersion?: string }
  socketFactory: SocketFactory
  /// Keyed by channelType (e.g. "terminal"). Unknown types are refused with
  /// close reason "unsupported".
  channelHandlers: Record<string, ChannelHandler>
  onStateChange?: (state: MachineConnectionState) => void
  onDisconnect?: (reason: MachineDisconnectReason) => void
  /// TOFU pin store for app-device keys. When provided, a channel open whose
  /// `peerPublicKey` conflicts with the pinned key for its `peerDeviceId` is
  /// refused ("rejected") — the hub is not trusted for key continuity. Keys
  /// pin only after a successful open (proof the opener holds the matching
  /// secret); opens without a device id (older hubs) proceed unpinned.
  peerKeyPins?: PeerKeyPinStore
  /// Fired on every refused open so integrators can log the substitution
  /// attempt with enough detail to investigate.
  onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  /// Coalesce outgoing relay envelopes for up to this long (see RelayOutbox).
  /// Default 0: every frame goes out immediately.
  relayCoalesceMs?: number
  /// Compresses an outgoing plaintext body on channels whose opener
  /// negotiated compressible framing; return undefined when not worthwhile.
  compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
  /// Inflates a DEFLATE-framed inbound body on negotiated channels. Absent =
  /// compressed inbound frames are refused (the app only compresses when the
  /// machine advertises support via this pair being wired up).
  decompressPayload?: (bytes: Uint8Array) => Uint8Array
  scheduleReconnect?: (callback: () => void, delayMs: number) => void
  scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
  welcomeTimeoutMs?: number
  heartbeatIntervalMs?: number
  pongTimeoutMs?: number
  random?: () => number
}

export class CloudMachineConnection {
  #socket: CloudSocket | undefined
  #outbox: RelayOutbox | undefined
  #state: MachineConnectionState = "stopped"
  #attempt = 0
  #stopped = true
  #reconnectGeneration = 0
  #cancelWelcomeTimeout: CancelTimeout | undefined
  #cancelHeartbeat: CancelTimeout | undefined
  #cancelPongTimeout: CancelTimeout | undefined
  /// The pipe-agnostic responder half of the channel protocol; this class is
  /// just the hub-relay pipe feeding it (socket, heartbeat, reconnect).
  readonly #receiver: ChannelReceiver

  constructor(private readonly options: MachineConnectionOptions) {
    this.#receiver = new ChannelReceiver({
      secretKey: options.credentials.secretKey,
      channelHandlers: options.channelHandlers,
      ...(options.peerKeyPins === undefined ? {} : { peerKeyPins: options.peerKeyPins }),
      ...(options.onPeerKeyMismatch === undefined
        ? {}
        : { onPeerKeyMismatch: options.onPeerKeyMismatch }),
      ...(options.compressPayload === undefined
        ? {}
        : { compressPayload: options.compressPayload }),
      ...(options.decompressPayload === undefined
        ? {}
        : { decompressPayload: options.decompressPayload }),
      sendEnvelope: (peerId, frame, payload) => this.#sendEnvelope(peerId, frame, payload),
      ready: () => this.#outbox !== undefined
    })
  }

  get state(): MachineConnectionState {
    return this.#state
  }

  start(): void {
    if (!this.#stopped) return
    this.#stopped = false
    this.#attempt = 0
    this.#connect()
  }

  stop(): void {
    this.#stopped = true
    this.#reconnectGeneration += 1
    this.#setState("stopped")
    this.#clearLivenessTimers()
    this.#dropOutbox()
    const socket = this.#socket
    this.#socket = undefined
    socket?.close(1000, "stopping")
    this.#receiver.dropAll("peer-gone")
  }

  #setState(state: MachineConnectionState): void {
    if (this.#state === state) return
    this.#state = state
    this.options.onStateChange?.(state)
  }

  #connect(): void {
    const { credentials } = this.options
    this.#setState(this.#attempt === 0 ? "connecting" : "reconnecting")
    const url = `${credentials.serverUrl.replace(/^http/, "ws")}/connect`
    const socket = this.options.socketFactory(url, { "x-api-key": credentials.apiKey })
    this.#socket = socket
    this.#outbox = new RelayOutbox({
      send: (message) => {
        try {
          socket.send(message)
        } catch {
          // The socket's close event drives teardown and reconnect.
        }
      },
      scheduleTimeout: (callback, delayMs) => this.#scheduleTimeout(callback, delayMs),
      coalesceMs: this.options.relayCoalesceMs ?? 0
    })
    this.#cancelWelcomeTimeout = this.#scheduleTimeout(() => {
      this.#cancelWelcomeTimeout = undefined
      this.#forceReconnect(socket, { kind: "welcome-timeout" })
    }, this.options.welcomeTimeoutMs ?? 15_000)
    socket.onopen = () => {
      if (this.#socket !== socket) return
      const device = {
        deviceId: credentials.deviceId,
        kind: "machine" as const,
        name: this.options.device.name,
        publicKey: credentials.publicKey,
        ...(this.options.device.os !== undefined ? { os: this.options.device.os } : {}),
        ...(this.options.device.appVersion !== undefined
          ? { appVersion: this.options.device.appVersion }
          : {})
      }
      try {
        socket.send(encodeCloudFrame({ t: "hello", protocol: CLOUD_PROTOCOL_VERSION, device }))
      } catch {
        this.#forceReconnect(socket, { kind: "send-failed", phase: "hello" })
      }
    }
    socket.onmessage = (data) => this.#onMessage(socket, data)
    socket.onclose = (code) => this.#onSocketClosed(socket, code)
  }

  #onMessage(socket: CloudSocket, data: string | Uint8Array): void {
    if (this.#socket !== socket) return
    // Binary messages are relay envelope batches; text is JSON control.
    if (typeof data !== "string") {
      let envelopes: WireRelayEnvelope[]
      try {
        envelopes = decodeRelayEnvelopes(data)
      } catch {
        return
      }
      for (const envelope of envelopes) {
        const header = parseHubToMachineRelayHeader(envelope.header)
        if (header === undefined) continue
        this.#receiver.handleRelay(
          header.peerId,
          header.frame,
          envelope.payload,
          header.peerPublicKey,
          header.peerDeviceId
        )
      }
      return
    }
    const frame = decodeHubToMachine(data)
    switch (frame.t) {
      case "welcome":
        this.#attempt = 0
        this.#cancelWelcomeTimeout?.()
        this.#cancelWelcomeTimeout = undefined
        this.#setState("connected")
        this.#scheduleHeartbeat(socket)
        return
      case "pong":
        if (this.#cancelPongTimeout !== undefined) {
          this.#cancelPongTimeout()
          this.#cancelPongTimeout = undefined
          this.#scheduleHeartbeat(socket)
        }
        return
      case "error":
        return
      case "peer-gone":
        this.#receiver.dropPeer(frame.peerId)
        return
    }
  }

  #scheduleHeartbeat(socket: CloudSocket): void {
    this.#cancelHeartbeat?.()
    this.#cancelHeartbeat = this.#scheduleTimeout(() => {
      this.#cancelHeartbeat = undefined
      if (this.#socket !== socket || this.#state !== "connected") return
      try {
        socket.send(encodeCloudFrame({ t: "ping" }))
      } catch {
        this.#forceReconnect(socket, { kind: "send-failed", phase: "heartbeat" })
        return
      }
      // A send implementation may synchronously surface a close; do not arm a
      // deadline for a socket that its close handler already detached.
      if (this.#socket !== socket) return
      this.#cancelPongTimeout?.()
      this.#cancelPongTimeout = this.#scheduleTimeout(() => {
        this.#cancelPongTimeout = undefined
        this.#forceReconnect(socket, { kind: "heartbeat-timeout" })
      }, this.options.pongTimeoutMs ?? 10_000)
    }, this.options.heartbeatIntervalMs ?? 30_000)
  }

  #onSocketClosed(socket: CloudSocket, code: number): void {
    // Also true after stop() and forced reconnect: both clear #socket before
    // closing or terminating the old transport.
    if (this.#socket !== socket) return
    this.#socket = undefined
    this.#clearLivenessTimers()
    this.#dropOutbox()
    this.#receiver.dropAll("peer-gone")
    this.options.onDisconnect?.({ kind: "socket-closed", code })
    if (code === 4201) {
      this.#setState("revoked")
      return
    }
    if (code === 4200) {
      this.#setState("unsupported-protocol")
      return
    }
    this.#scheduleReconnect()
  }

  #forceReconnect(socket: CloudSocket, reason: MachineDisconnectReason): void {
    if (this.#socket !== socket || this.#stopped) return
    this.#socket = undefined
    this.#clearLivenessTimers()
    this.#dropOutbox()
    this.#receiver.dropAll("peer-gone")
    this.options.onDisconnect?.(reason)
    try {
      if (socket.terminate !== undefined) socket.terminate()
      else socket.close(4001, reason.kind)
    } catch {
      // The connection is already detached locally; reconnect does not depend
      // on a broken transport completing its close handshake.
    }
    this.#scheduleReconnect()
  }

  #scheduleReconnect(): void {
    const delay = reconnectDelayMs(this.#attempt, this.options.random ?? Math.random)
    this.#attempt += 1
    this.#setState("reconnecting")
    const schedule =
      this.options.scheduleReconnect ??
      ((callback: () => void, ms: number) => void setTimeout(callback, ms))
    const generation = ++this.#reconnectGeneration
    schedule(() => {
      if (!this.#stopped && generation === this.#reconnectGeneration) this.#connect()
    }, delay)
  }

  #scheduleTimeout(callback: () => void, delayMs: number): CancelTimeout {
    if (this.options.scheduleTimeout !== undefined) {
      return this.options.scheduleTimeout(callback, delayMs)
    }
    const timeout = setTimeout(callback, delayMs)
    return () => clearTimeout(timeout)
  }

  #clearLivenessTimers(): void {
    this.#cancelWelcomeTimeout?.()
    this.#cancelHeartbeat?.()
    this.#cancelPongTimeout?.()
    this.#cancelWelcomeTimeout = undefined
    this.#cancelHeartbeat = undefined
    this.#cancelPongTimeout = undefined
  }

  #dropOutbox(): void {
    this.#outbox?.clear()
    this.#outbox = undefined
  }

  /// Queues one relay envelope toward the hub (empty payload for
  /// credit/close frames, whose parameters live in the header).
  #sendEnvelope(
    peerId: string,
    frame: RelayFrameHeader,
    payload: Uint8Array = new Uint8Array(0)
  ): void {
    this.#outbox?.push({ peerId, frame }, payload)
  }
}
