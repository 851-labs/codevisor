import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToMachine,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  parseHubToMachineRelayHeader,
  type ChannelCloseReason,
  type RelayFrameHeader,
  type WireRelayEnvelope
} from "@codevisor/api"
import { acceptChannel, openJson, type ChannelCipher } from "@codevisor/cloud-crypto"
import {
  makeLiveChannel,
  PLAINTEXT_DEFLATE,
  PLAINTEXT_RAW,
  type ChannelHandler,
  type LiveChannel
} from "./incoming-channel.js"
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

const utf8Decoder = new TextDecoder()

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
  #channels = new Map<string, LiveChannel>()

  constructor(private readonly options: MachineConnectionOptions) {}

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
    this.#dropAllChannels("peer-gone")
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
        this.#onRelay(
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
      case "peer-gone": {
        for (const [key, live] of this.#channels) {
          if (key.startsWith(`${frame.peerId}/`)) {
            this.#channels.delete(key)
            live.channel.onClosed?.("peer-gone")
          }
        }
        return
      }
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
    this.#dropAllChannels("peer-gone")
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
    this.#dropAllChannels("peer-gone")
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

  #onRelay(
    peerId: string,
    frame: RelayFrameHeader,
    payload: Uint8Array,
    peerPublicKey: string | undefined,
    peerDeviceId: string | undefined
  ): void {
    const key = `${peerId}/${frame.channelId}`
    if (frame.t === "open") {
      if (peerPublicKey === undefined || this.#channels.has(key)) {
        this.#refuse(peerId, frame.channelId, "protocol-error")
        return
      }
      // TOFU: a key that conflicts with the pin for this app device means the
      // hub (or someone controlling it) substituted the opener's identity —
      // refuse before any key agreement happens.
      const pins = this.options.peerKeyPins
      if (pins !== undefined && peerDeviceId !== undefined) {
        const pinned = pins.get(peerDeviceId)
        if (pinned !== undefined && pinned !== peerPublicKey) {
          this.options.onPeerKeyMismatch?.({
            deviceId: peerDeviceId,
            pinned,
            presented: peerPublicKey
          })
          this.#refuse(peerId, frame.channelId, "rejected")
          return
        }
      }
      let cipher: ChannelCipher
      let openPayload: { channelType?: unknown; params?: unknown; compress?: unknown }
      try {
        cipher = acceptChannel(
          this.options.credentials.secretKey,
          peerPublicKey,
          frame.ephemeralKey
        )
        openPayload = openJson(cipher, frame.channelId, "opener-to-responder", 0, payload) as {
          channelType?: unknown
          params?: unknown
          compress?: unknown
        }
      } catch {
        this.#refuse(peerId, frame.channelId, "crypto-error")
        return
      }
      if (typeof openPayload.channelType !== "string") {
        this.#refuse(peerId, frame.channelId, "protocol-error")
        return
      }
      const handler = this.options.channelHandlers[openPayload.channelType]
      if (handler === undefined) {
        this.#refuse(peerId, frame.channelId, "unsupported")
        return
      }
      // Pin only now: the sealed payload decrypted, so the opener provably
      // holds the secret matching the presented key — a spoofed key can never
      // get itself pinned by failing crypto.
      if (pins !== undefined && peerDeviceId !== undefined) {
        pins.set(peerDeviceId, peerPublicKey)
      }
      const live = makeLiveChannel({
        channelId: frame.channelId,
        peerId,
        channelType: openPayload.channelType,
        params: openPayload.params,
        cipher,
        // Prefix-framed (compressible) payloads are opener-negotiated; the
        // responder honours the framing even without a compressor (RAW).
        compressed: openPayload.compress === true,
        ...(this.options.compressPayload === undefined
          ? {}
          : { compress: this.options.compressPayload }),
        current: () => this.#channels.get(key),
        remove: () => this.#channels.delete(key),
        ready: () => this.#outbox !== undefined,
        sendEnvelope: (relayFrame, relayPayload) =>
          this.#sendEnvelope(peerId, relayFrame, relayPayload)
      })
      this.#channels.set(key, live)
      handler(live.channel)
      return
    }
    const live = this.#channels.get(key)
    if (live === undefined) {
      // A frame for a channel we don't know about — typically the app kept a
      // channel alive across our socket reconnect (channel state is in-memory
      // and did not survive it). Answer with a close instead of dropping the
      // frame silently, so the app tears down its side and resumes from its
      // cursor rather than waiting forever on a dead channel.
      if (frame.t !== "close") {
        this.#refuse(peerId, frame.channelId, "peer-disconnected")
      }
      return
    }
    if (frame.t === "close") {
      this.#channels.delete(key)
      live.channel.onClosed?.(frame.reason)
      return
    }
    // credit and data share one opener→responder seq counter (the protocol's
    // per-direction counter spans every frame type): openers allocate credit
    // seqs from the same counter as data seqs, so skipping credit here would
    // make the next data frame look like a gap and kill a healthy channel.
    if (frame.t === "credit") {
      if (frame.seq !== live.nextReceiveSeq) {
        this.#channels.delete(key)
        this.#refuse(peerId, frame.channelId, "protocol-error")
        live.channel.onClosed?.("protocol-error")
        return
      }
      live.nextReceiveSeq += 1
      live.channel.onCredit?.(frame.bytes)
      return
    }
    // data — enforce the monotonic seq contract bound into the AAD.
    if (frame.seq !== live.nextReceiveSeq) {
      this.#channels.delete(key)
      this.#refuse(peerId, frame.channelId, "protocol-error")
      live.channel.onClosed?.("protocol-error")
      return
    }
    let value: unknown
    try {
      let plaintext = live.cipher.open(frame.channelId, "opener-to-responder", frame.seq, payload)
      if (live.compressed) plaintext = this.#unframe(plaintext)
      value =
        live.channel.onBytes === null
          ? (JSON.parse(utf8Decoder.decode(plaintext)) as unknown)
          : plaintext
    } catch {
      this.#channels.delete(key)
      this.#refuse(peerId, frame.channelId, "crypto-error")
      live.channel.onClosed?.("crypto-error")
      return
    }
    const sealedBytes = payload.byteLength
    if (live.flowControlled) {
      if (sealedBytes > live.inboundCredit) {
        this.#channels.delete(key)
        this.#refuse(peerId, frame.channelId, "protocol-error")
        live.channel.onClosed?.("protocol-error")
        return
      }
      live.inboundCredit -= sealedBytes
    }
    live.nextReceiveSeq += 1
    if (value instanceof Uint8Array) live.channel.onBytes?.(value, sealedBytes)
    else live.channel.onData?.(value)
  }

  /// Strips the negotiated framing byte, inflating DEFLATE bodies. Throws on
  /// unknown framing or a missing/failing decompressor (surfaced to the peer
  /// as crypto-error, same as any undecodable payload).
  #unframe(plaintext: Uint8Array): Uint8Array {
    if (plaintext.byteLength < 1) throw new Error("missing plaintext framing byte")
    const body = plaintext.subarray(1)
    if (plaintext[0] === PLAINTEXT_RAW) return body
    if (plaintext[0] === PLAINTEXT_DEFLATE && this.options.decompressPayload !== undefined) {
      return this.options.decompressPayload(body)
    }
    throw new Error("unsupported plaintext framing")
  }

  #refuse(peerId: string, channelId: string, reason: ChannelCloseReason): void {
    this.#sendEnvelope(peerId, { t: "close", channelId, seq: 0, reason })
  }

  #dropAllChannels(reason: ChannelCloseReason | "peer-gone"): void {
    const channels = [...this.#channels.values()]
    this.#channels.clear()
    for (const live of channels) live.channel.onClosed?.(reason)
  }
}
