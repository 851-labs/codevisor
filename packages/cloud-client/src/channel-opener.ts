import type { ChannelCloseReason, RelayFrameHeader } from "@codevisor/api"
import { openChannel, openJson, sealJson, type ChannelCipher } from "@codevisor/cloud-crypto"

import type { PeerKeyPinStore } from "./peer-pins.js"

/// The opener half of the sealed channel protocol — the mirror of
/// ChannelReceiver, used by a machine to open channels toward another
/// machine on the same account (the hub routes them; see relay-routing.ts).
/// Pipe-agnostic like the receiver: the owner feeds relay frames addressed
/// by `machineId` into `handleRelay`, hub errors into `handleHubError`, and
/// presence transitions into `dropMachine`; outbound frames leave through
/// `sendEnvelope`.
///
/// Channels carry JSON values only (no flow control, no compression): they
/// are request/response channels, not streams.

/// Why an outgoing channel ended without the opener closing it.
export type OutgoingChannelEnd =
  /// The responder closed the channel (after answering, or to refuse it).
  | { readonly kind: "peer-closed"; readonly reason: ChannelCloseReason }
  /// The hub could not deliver this channel's frames to the target.
  | { readonly kind: "undeliverable" }
  /// The target machine went offline, or restarted and lost the channel.
  | { readonly kind: "peer-gone" }
  /// This machine's own hub connection ended without resuming.
  | { readonly kind: "connection-lost" }
  /// The responder sent a frame that failed sequencing or decryption.
  | { readonly kind: "protocol-error" }

export interface OutgoingChannel {
  readonly channelId: string
  readonly machineId: string
  /// Seals and sends one JSON value. No-op once the channel ended.
  send(value: unknown): void
  /// Ends the channel from this side (the responder sees `reason`). Does not
  /// fire `onEnded`.
  close(reason?: ChannelCloseReason): void
  onData: ((value: unknown) => void) | null
  onEnded: ((end: OutgoingChannelEnd) => void) | null
}

export interface OpenTarget {
  readonly deviceId: string
  /// The target's static public key, from hub presence. TOFU-pinned under
  /// the device id once the target proves it holds the matching secret.
  readonly publicKey: string
}

export class ChannelKeyMismatchError extends Error {
  override readonly name = "ChannelKeyMismatchError"
}

export interface ChannelOpenerOptions {
  /// This machine's static X25519 secret key (base64url).
  secretKey: string
  /// Shared with the receiver's pins: device ids are unique across kinds.
  peerKeyPins?: PeerKeyPinStore
  onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  sendEnvelope: (machineId: string, frame: RelayFrameHeader, payload?: Uint8Array) => void
  newChannelId?: () => string
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

  /// Opens a channel and sends its sealed open frame. Throws
  /// ChannelKeyMismatchError, sending nothing, when the target presents a
  /// key other than the one pinned for it.
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
    const channelId = (this.options.newChannelId ?? (() => crypto.randomUUID()))()
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
      // A late answer on a channel this side already let go: tell the
      // responder to stop instead of letting it stream into the void.
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
    // One responder→opener seq counter spans data and credit frames.
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
    // The responder decrypted our open and answered under the agreed key:
    // it holds the secret for the presented public key, so pin it.
    this.options.peerKeyPins?.set(live.target.deviceId, live.target.publicKey)
    live.channel.onData?.(value)
  }

  /// A hub error. Channel-scoped errors mean that channel's frames were not
  /// delivered; machine-wide ones mean the target is gone.
  handleHubError(machineId: string, channelId: string | undefined): void {
    if (channelId === undefined) {
      this.dropMachine(machineId)
      return
    }
    this.#end(`${machineId}/${channelId}`, { kind: "undeliverable" })
  }

  /// The target went offline or restarted: its channel state is gone.
  dropMachine(machineId: string): void {
    for (const [key, live] of this.#channels) {
      if (live.channel.machineId === machineId) this.#end(key, { kind: "peer-gone" })
    }
  }

  /// This machine's own pipe died for good.
  dropAll(): void {
    // Deleting the visited entry during Map iteration is well-defined.
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
