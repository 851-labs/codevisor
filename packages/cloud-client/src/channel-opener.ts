import type { ChannelCloseReason, RelayFrameHeader } from "@codevisor/api"
import { openChannel, openJson, sealJson, type ChannelCipher } from "@codevisor/cloud-crypto"

import type { PeerKeyPinStore } from "./peer-pins.js"

export type OutgoingChannelEnd =
  | { readonly kind: "peer-closed"; readonly reason: ChannelCloseReason }
  | { readonly kind: "undeliverable" }
  | { readonly kind: "peer-gone" }
  | { readonly kind: "connection-lost" }
  | { readonly kind: "protocol-error" }

export interface OutgoingChannel {
  readonly channelId: string
  readonly machineId: string
  send(value: unknown): void
  close(reason?: ChannelCloseReason): void
  onData: ((value: unknown) => void) | null
  onEnded: ((end: OutgoingChannelEnd) => void) | null
}

export interface OpenTarget {
  readonly deviceId: string
  readonly publicKey: string
}

export class ChannelKeyMismatchError extends Error {
  override readonly name = "ChannelKeyMismatchError"
}

export interface ChannelOpenerOptions {
  secretKey: string
  peerKeyPins?: PeerKeyPinStore
  onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  sendEnvelope: (machineId: string, frame: RelayFrameHeader, payload?: Uint8Array) => void
}

interface LiveOutgoing {
  readonly channel: OutgoingChannel
  readonly cipher: ChannelCipher
  readonly target: OpenTarget
  nextSendSeq: number
  nextReceiveSeq: number
}

export class ChannelOpener {
  #channels = new Map<string, LiveOutgoing>()

  constructor(private readonly options: ChannelOpenerOptions) {}

  open(target: OpenTarget, channelType: string, params?: unknown): OutgoingChannel {
    const pinned = this.options.peerKeyPins?.get(target.deviceId)
    if (pinned !== undefined && pinned !== target.publicKey) {
      this.options.onPeerKeyMismatch?.({
        deviceId: target.deviceId,
        pinned,
        presented: target.publicKey
      })
      throw new ChannelKeyMismatchError(`the key for machine ${target.deviceId} changed`)
    }
    const channelId = crypto.randomUUID()
    const opened = openChannel(this.options.secretKey, target.publicKey)
    const key = `${target.deviceId}/${channelId}`
    const channel: OutgoingChannel = {
      channelId,
      machineId: target.deviceId,
      send: (value) => {
        const live = this.#channels.get(key)
        if (live === undefined) return
        const seq = live.nextSendSeq++
        this.options.sendEnvelope(
          target.deviceId,
          { t: "data", channelId, seq },
          sealJson(live.cipher, channelId, "opener-to-responder", seq, value)
        )
      },
      close: (reason = "done") => {
        const live = this.#channels.get(key)
        if (live === undefined) return
        this.#channels.delete(key)
        this.options.sendEnvelope(target.deviceId, {
          t: "close",
          channelId,
          seq: live.nextSendSeq,
          reason
        })
      },
      onData: null,
      onEnded: null
    }
    this.#channels.set(key, {
      channel,
      cipher: opened.cipher,
      target,
      nextSendSeq: 1,
      nextReceiveSeq: 0
    })
    this.options.sendEnvelope(
      target.deviceId,
      { t: "open", channelId, seq: 0, ephemeralKey: opened.ephemeralPublicKey },
      sealJson(opened.cipher, channelId, "opener-to-responder", 0, {
        channelType,
        ...(params === undefined ? {} : { params })
      })
    )
    return channel
  }

  handleRelay(machineId: string, frame: RelayFrameHeader, payload: Uint8Array): void {
    const key = `${machineId}/${frame.channelId}`
    const live = this.#channels.get(key)
    if (live === undefined) {
      if (frame.t !== "close") {
        this.options.sendEnvelope(machineId, {
          t: "close",
          channelId: frame.channelId,
          seq: 0,
          reason: "peer-disconnected"
        })
      }
      return
    }
    if (frame.t === "close") {
      this.#end(key, { kind: "peer-closed", reason: frame.reason })
      return
    }
    if (frame.t === "open" || frame.seq !== live.nextReceiveSeq) {
      this.#abort(live, "protocol-error")
      return
    }
    live.nextReceiveSeq += 1
    if (frame.t === "credit") return
    let value: unknown
    try {
      value = openJson(live.cipher, frame.channelId, "responder-to-opener", frame.seq, payload)
    } catch {
      this.#abort(live, "crypto-error")
      return
    }
    this.options.peerKeyPins?.set(live.target.deviceId, live.target.publicKey)
    live.channel.onData?.(value)
  }

  handleHubError(machineId: string, channelId: string | undefined): void {
    if (channelId === undefined) {
      this.dropMachine(machineId)
      return
    }
    this.#end(`${machineId}/${channelId}`, { kind: "undeliverable" })
  }

  dropMachine(machineId: string): void {
    for (const [key, live] of this.#channels) {
      if (live.channel.machineId === machineId) this.#end(key, { kind: "peer-gone" })
    }
  }

  dropAll(): void {
    for (const key of this.#channels.keys()) this.#end(key, { kind: "connection-lost" })
  }

  #end(key: string, end: OutgoingChannelEnd): void {
    const live = this.#channels.get(key)
    if (live === undefined) return
    this.#channels.delete(key)
    live.channel.onEnded?.(end)
  }

  #abort(live: LiveOutgoing, reason: ChannelCloseReason): void {
    live.channel.close(reason)
    live.channel.onEnded?.({ kind: "protocol-error" })
  }
}
