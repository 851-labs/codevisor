import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToMachine,
  encodeCloudFrame,
  type ChannelCloseReason,
  type RelayFrame
} from "@codevisor/api"
import { acceptChannel, openJson, sealJson, type ChannelCipher } from "@codevisor/cloud-crypto"
import type { ChannelHandler, IncomingChannel } from "./incoming-channel.js"
import type { MachineCredentials } from "./login.js"
import {
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
  scheduleReconnect?: (callback: () => void, delayMs: number) => void
  scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
  welcomeTimeoutMs?: number
  heartbeatIntervalMs?: number
  pongTimeoutMs?: number
  random?: () => number
}

interface LiveChannel {
  cipher: ChannelCipher
  channel: IncomingChannel
  nextReceiveSeq: number
  nextSendSeq: number
  flowControlled: boolean
  inboundCredit: number
}

export class CloudMachineConnection {
  #socket: CloudSocket | undefined
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
    socket.onmessage = (data) => this.#onFrame(socket, data)
    socket.onclose = (code) => this.#onSocketClosed(socket, code)
  }

  #onFrame(socket: CloudSocket, data: string): void {
    if (this.#socket !== socket) return
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
      case "relay":
        this.#onRelay(socket, frame.peerId, frame.frame, frame.peerPublicKey, frame.peerDeviceId)
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

  #onRelay(
    socket: CloudSocket,
    peerId: string,
    frame: RelayFrame,
    peerPublicKey: string | undefined,
    peerDeviceId: string | undefined
  ): void {
    const key = `${peerId}/${frame.channelId}`
    if (frame.t === "open") {
      if (peerPublicKey === undefined || this.#channels.has(key)) {
        this.#refuse(socket, peerId, frame.channelId, "protocol-error")
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
          this.#refuse(socket, peerId, frame.channelId, "rejected")
          return
        }
      }
      let cipher: ChannelCipher
      let payload: { channelType?: unknown; params?: unknown }
      try {
        cipher = acceptChannel(
          this.options.credentials.secretKey,
          peerPublicKey,
          frame.ephemeralKey
        )
        payload = openJson(cipher, frame.channelId, "opener-to-responder", 0, frame.sealed) as {
          channelType?: unknown
          params?: unknown
        }
      } catch {
        this.#refuse(socket, peerId, frame.channelId, "crypto-error")
        return
      }
      if (typeof payload.channelType !== "string") {
        this.#refuse(socket, peerId, frame.channelId, "protocol-error")
        return
      }
      const handler = this.options.channelHandlers[payload.channelType]
      if (handler === undefined) {
        this.#refuse(socket, peerId, frame.channelId, "unsupported")
        return
      }
      // Pin only now: the sealed payload decrypted, so the opener provably
      // holds the secret matching the presented key — a spoofed key can never
      // get itself pinned by failing crypto.
      if (pins !== undefined && peerDeviceId !== undefined) {
        pins.set(peerDeviceId, peerPublicKey)
      }
      const live: LiveChannel = {
        cipher,
        nextReceiveSeq: 1,
        nextSendSeq: 0,
        flowControlled: false,
        inboundCredit: 0,
        channel: {
          channelId: frame.channelId,
          peerId,
          channelType: payload.channelType,
          params: payload.params,
          send: (value) => {
            const current = this.#channels.get(key)
            if (current === undefined || this.#socket === undefined) return
            const seq = current.nextSendSeq
            current.nextSendSeq += 1
            this.#socket.send(
              encodeCloudFrame({
                t: "relay",
                peerId,
                frame: {
                  t: "data",
                  channelId: frame.channelId,
                  seq,
                  sealed: sealJson(
                    current.cipher,
                    frame.channelId,
                    "responder-to-opener",
                    seq,
                    value
                  )
                }
              })
            )
          },
          sendBytes: (value) => {
            const current = this.#channels.get(key)
            if (current === undefined || this.#socket === undefined) return undefined
            const seq = current.nextSendSeq
            current.nextSendSeq += 1
            const sealed = current.cipher.seal(frame.channelId, "responder-to-opener", seq, value)
            this.#socket.send(
              encodeCloudFrame({
                t: "relay",
                peerId,
                frame: { t: "data", channelId: frame.channelId, seq, sealed }
              })
            )
            return sealed.box.length
          },
          deferInboundCredit: () => {
            const current = this.#channels.get(key)
            if (current !== undefined) current.flowControlled = true
          },
          grantCredit: (bytes) => {
            const current = this.#channels.get(key)
            if (
              current === undefined ||
              this.#socket === undefined ||
              !Number.isSafeInteger(bytes) ||
              bytes <= 0 ||
              current.inboundCredit > Number.MAX_SAFE_INTEGER - bytes
            ) {
              return
            }
            current.inboundCredit += bytes
            const seq = current.nextSendSeq
            current.nextSendSeq += 1
            this.#socket.send(
              encodeCloudFrame({
                t: "relay",
                peerId,
                frame: { t: "credit", channelId: frame.channelId, seq, bytes }
              })
            )
          },
          close: (reason) => {
            const current = this.#channels.get(key)
            if (current === undefined) return
            this.#channels.delete(key)
            this.#socket?.send(
              encodeCloudFrame({
                t: "relay",
                peerId,
                frame: {
                  t: "close",
                  channelId: frame.channelId,
                  seq: current.nextSendSeq,
                  reason
                }
              })
            )
          },
          onData: null,
          onBytes: null,
          onCredit: null,
          onClosed: null
        }
      }
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
        this.#refuse(socket, peerId, frame.channelId, "peer-disconnected")
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
      if (
        frame.seq !== live.nextReceiveSeq ||
        !Number.isSafeInteger(frame.bytes) ||
        frame.bytes <= 0
      ) {
        this.#channels.delete(key)
        this.#refuse(socket, peerId, frame.channelId, "protocol-error")
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
      this.#refuse(socket, peerId, frame.channelId, "protocol-error")
      live.channel.onClosed?.("protocol-error")
      return
    }
    let value: unknown
    try {
      value =
        live.channel.onBytes === null
          ? openJson(live.cipher, frame.channelId, "opener-to-responder", frame.seq, frame.sealed)
          : live.cipher.open(frame.channelId, "opener-to-responder", frame.seq, frame.sealed)
    } catch {
      this.#channels.delete(key)
      this.#refuse(socket, peerId, frame.channelId, "crypto-error")
      live.channel.onClosed?.("crypto-error")
      return
    }
    const sealedBytes = frame.sealed.box.length
    if (live.flowControlled) {
      if (sealedBytes > live.inboundCredit) {
        this.#channels.delete(key)
        this.#refuse(socket, peerId, frame.channelId, "protocol-error")
        live.channel.onClosed?.("protocol-error")
        return
      }
      live.inboundCredit -= sealedBytes
    }
    live.nextReceiveSeq += 1
    if (value instanceof Uint8Array) live.channel.onBytes?.(value, sealedBytes)
    else live.channel.onData?.(value)
  }

  #refuse(
    socket: CloudSocket,
    peerId: string,
    channelId: string,
    reason: ChannelCloseReason
  ): void {
    socket.send(
      encodeCloudFrame({ t: "relay", peerId, frame: { t: "close", channelId, seq: 0, reason } })
    )
  }

  #dropAllChannels(reason: ChannelCloseReason | "peer-gone"): void {
    const channels = [...this.#channels.values()]
    this.#channels.clear()
    for (const live of channels) live.channel.onClosed?.(reason)
  }
}
