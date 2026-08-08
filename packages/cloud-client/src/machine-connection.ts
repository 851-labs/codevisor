import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToMachine,
  encodeCloudFrame,
  type ChannelCloseReason,
  type RelayFrame
} from "@codevisor/api"
import { acceptChannel, openJson, sealJson, type ChannelCipher } from "@codevisor/cloud-crypto"
import type { MachineCredentials } from "./login.js"

/// Minimal WebSocket surface both `ws` (Node/Bun) and the browser API can be
/// adapted to; injected so the connection logic is unit-testable.
export interface CloudSocket {
  send(data: string): void
  close(code?: number, reason?: string): void
  onopen: (() => void) | null
  onmessage: ((data: string) => void) | null
  onclose: ((code: number) => void) | null
}

export type SocketFactory = (url: string, headers: Record<string, string>) => CloudSocket

export type MachineConnectionState =
  | "connecting"
  | "connected"
  | "reconnecting"
  | "stopped"
  /// Fatal states — the hub told us not to come back with these credentials.
  | "revoked"
  | "unsupported-protocol"

/// An app-opened channel as seen by machine-side handlers. Payloads are
/// sealed/opened transparently; handlers only ever see plaintext values.
export interface IncomingChannel {
  channelId: string
  peerId: string
  channelType: string
  params: unknown
  send(value: unknown): void
  close(reason: ChannelCloseReason): void
  onData: ((value: unknown) => void) | null
  onCredit: ((bytes: number) => void) | null
  onClosed: ((reason: ChannelCloseReason | "peer-gone") => void) | null
}

export type ChannelHandler = (channel: IncomingChannel) => void

/// Exponential backoff with full jitter; exported for tests and reuse.
export const reconnectDelayMs = (
  attempt: number,
  random: () => number,
  baseMs = 500,
  maxMs = 30_000
): number => Math.floor(random() * Math.min(maxMs, baseMs * 2 ** Math.min(attempt, 10)))

export interface MachineConnectionOptions {
  credentials: MachineCredentials
  device: { name: string; os?: string; appVersion?: string }
  socketFactory: SocketFactory
  /// Keyed by channelType (e.g. "terminal"). Unknown types are refused with
  /// close reason "unsupported".
  channelHandlers: Record<string, ChannelHandler>
  onStateChange?: (state: MachineConnectionState) => void
  scheduleReconnect?: (callback: () => void, delayMs: number) => void
  random?: () => number
}

interface LiveChannel {
  cipher: ChannelCipher
  channel: IncomingChannel
  nextReceiveSeq: number
  nextSendSeq: number
}

export class CloudMachineConnection {
  #socket: CloudSocket | undefined
  #state: MachineConnectionState = "stopped"
  #attempt = 0
  #stopped = true
  /// Keyed by `${peerId}/${channelId}`.
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
    this.#setState("stopped")
    this.#socket?.close(1000, "stopping")
    this.#socket = undefined
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
    socket.onopen = () => {
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
      socket.send(encodeCloudFrame({ t: "hello", protocol: CLOUD_PROTOCOL_VERSION, device }))
    }
    socket.onmessage = (data) => this.#onFrame(socket, data)
    socket.onclose = (code) => {
      // Also true after stop(): stop clears #socket before closing it.
      if (this.#socket !== socket) return
      this.#socket = undefined
      this.#dropAllChannels("peer-gone")
      if (code === 4201) {
        this.#setState("revoked")
        return
      }
      if (code === 4200) {
        this.#setState("unsupported-protocol")
        return
      }
      const delay = reconnectDelayMs(this.#attempt, this.options.random ?? Math.random)
      this.#attempt += 1
      this.#setState("reconnecting")
      const schedule =
        this.options.scheduleReconnect ??
        ((callback: () => void, ms: number) => void setTimeout(callback, ms))
      schedule(() => {
        if (!this.#stopped) this.#connect()
      }, delay)
    }
  }

  #onFrame(socket: CloudSocket, data: string): void {
    const frame = decodeHubToMachine(data)
    switch (frame.t) {
      case "welcome":
        this.#attempt = 0
        this.#setState("connected")
        return
      case "pong":
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
        this.#onRelay(socket, frame.peerId, frame.frame, frame.peerPublicKey)
        return
    }
  }

  #onRelay(
    socket: CloudSocket,
    peerId: string,
    frame: RelayFrame,
    peerPublicKey: string | undefined
  ): void {
    const key = `${peerId}/${frame.channelId}`
    if (frame.t === "open") {
      if (peerPublicKey === undefined || this.#channels.has(key)) {
        this.#refuse(socket, peerId, frame.channelId, "protocol-error")
        return
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
      const live: LiveChannel = {
        cipher,
        nextReceiveSeq: 1,
        nextSendSeq: 0,
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
          onCredit: null,
          onClosed: null
        }
      }
      this.#channels.set(key, live)
      handler(live.channel)
      return
    }
    const live = this.#channels.get(key)
    if (live === undefined) return
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
      value = openJson(live.cipher, frame.channelId, "opener-to-responder", frame.seq, frame.sealed)
    } catch {
      this.#channels.delete(key)
      this.#refuse(socket, peerId, frame.channelId, "crypto-error")
      live.channel.onClosed?.("crypto-error")
      return
    }
    live.nextReceiveSeq += 1
    live.channel.onData?.(value)
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
