import {
  GATEWAY_CHANNEL_TYPE,
  type ChannelCloseReason,
  type CloudDeviceKind,
  type RelayFrameHeader,
  isRecord
} from "@codevisor/api"
import { acceptChannel, openJson, type ChannelCipher } from "@codevisor/cloud-crypto"

import {
  makeLiveChannel,
  PLAINTEXT_DEFLATE,
  PLAINTEXT_RAW,
  type ChannelHandler,
  type LiveChannel
} from "./incoming-channel.js"
import type { PeerKeyPinStore } from "./peer-pins.js"

const utf8Decoder = new TextDecoder()

const notifyClosed = (live: LiveChannel, reason: ChannelCloseReason | "peer-gone"): void => {
  try {
    live.channel.onClosed?.(reason)
  } catch {}
}

export interface ChannelReceiverOptions {
  secretKey: string
  channelHandlers: Record<string, ChannelHandler>
  peerKeyPins?: PeerKeyPinStore
  onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
  decompressPayload?: (bytes: Uint8Array) => Uint8Array
  sendEnvelope: (peerId: string, frame: RelayFrameHeader, payload?: Uint8Array) => void
  ready: () => boolean
}

export class ChannelReceiver {
  #channels = new Map<string, LiveChannel>()

  constructor(private readonly options: ChannelReceiverOptions) {}

  handleRelay(
    peerId: string,
    frame: RelayFrameHeader,
    payload: Uint8Array,
    peerPublicKey: string | undefined,
    peerDeviceId: string | undefined,
    peerKind?: CloudDeviceKind
  ): void {
    const key = `${peerId}/${frame.channelId}`
    if (frame.t === "open") {
      this.#handleOpen(key, peerId, frame, payload, peerPublicKey, peerDeviceId, peerKind)
      return
    }
    const live = this.#channels.get(key)
    if (live === undefined) {
      if (frame.t !== "close") {
        this.#refuse(peerId, frame.channelId, "peer-disconnected")
      }
      return
    }
    if (frame.t === "close") {
      this.#channels.delete(key)
      notifyClosed(live, frame.reason)
      return
    }
    if (frame.seq !== live.nextReceiveSeq) {
      this.#abort(key, peerId, frame.channelId, live, "protocol-error")
      return
    }
    if (frame.t === "credit") {
      live.nextReceiveSeq += 1
      this.#runHandler(key, peerId, frame.channelId, live, () => {
        if (!live.receiveCredit(frame.bytes)) {
          this.#abort(key, peerId, frame.channelId, live, "protocol-error")
        }
      })
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
      this.#abort(key, peerId, frame.channelId, live, "crypto-error")
      return
    }
    const sealedBytes = payload.byteLength
    if (live.flowControlled) {
      if (sealedBytes > live.inboundCredit) {
        this.#abort(key, peerId, frame.channelId, live, "protocol-error")
        return
      }
      live.inboundCredit -= sealedBytes
    }
    live.nextReceiveSeq += 1
    this.#runHandler(key, peerId, frame.channelId, live, () => {
      if (value instanceof Uint8Array) live.channel.onBytes?.(value, sealedBytes)
      else live.channel.onData?.(value, sealedBytes)
    })
  }

  dropPeer(peerId: string): void {
    for (const [key, live] of this.#channels) {
      if (key.startsWith(`${peerId}/`)) {
        this.#channels.delete(key)
        notifyClosed(live, "peer-gone")
      }
    }
  }

  dropAll(reason: ChannelCloseReason | "peer-gone"): void {
    const channels = [...this.#channels.values()]
    this.#channels.clear()
    for (const live of channels) notifyClosed(live, reason)
  }

  #handleOpen(
    key: string,
    peerId: string,
    frame: Extract<RelayFrameHeader, { t: "open" }>,
    payload: Uint8Array,
    peerPublicKey: string | undefined,
    peerDeviceId: string | undefined,
    peerKind: CloudDeviceKind | undefined
  ): void {
    if (peerPublicKey === undefined || this.#channels.has(key)) {
      this.#refuse(peerId, frame.channelId, "protocol-error")
      return
    }
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
    let openPayload: unknown
    try {
      cipher = acceptChannel(this.options.secretKey, peerPublicKey, frame.ephemeralKey)
      openPayload = openJson(cipher, frame.channelId, "opener-to-responder", 0, payload)
    } catch {
      this.#refuse(peerId, frame.channelId, "crypto-error")
      return
    }
    if (!isRecord(openPayload) || typeof openPayload.channelType !== "string") {
      this.#refuse(peerId, frame.channelId, "protocol-error")
      return
    }
    if (peerKind === "machine" && openPayload.channelType !== GATEWAY_CHANNEL_TYPE) {
      this.#refuse(peerId, frame.channelId, "rejected")
      return
    }
    const handler = this.options.channelHandlers[openPayload.channelType]
    if (handler === undefined) {
      this.#refuse(peerId, frame.channelId, "unsupported")
      return
    }
    if (pins !== undefined && peerDeviceId !== undefined) {
      pins.set(peerDeviceId, peerPublicKey)
    }
    const live = makeLiveChannel({
      channelId: frame.channelId,
      peerId,
      peer: {
        publicKey: peerPublicKey,
        ...(peerDeviceId === undefined ? {} : { deviceId: peerDeviceId })
      },
      channelType: openPayload.channelType,
      params: openPayload.params,
      cipher,
      compressed: openPayload.compress === true,
      flowControl: openPayload.flowControl === true,
      ...(this.options.compressPayload === undefined
        ? {}
        : { compress: this.options.compressPayload }),
      current: () => this.#channels.get(key),
      remove: () => this.#channels.delete(key),
      ready: this.options.ready,
      sendEnvelope: (relayFrame, relayPayload) =>
        this.options.sendEnvelope(peerId, relayFrame, relayPayload)
    })
    this.#channels.set(key, live)
    this.#runHandler(key, peerId, frame.channelId, live, () => handler(live.channel))
  }

  #runHandler(
    key: string,
    peerId: string,
    channelId: string,
    live: LiveChannel,
    run: () => void
  ): void {
    try {
      run()
    } catch {
      if (this.#channels.get(key) === live) this.#abort(key, peerId, channelId, live, "rejected")
    }
  }

  #unframe(plaintext: Uint8Array): Uint8Array {
    if (plaintext.byteLength < 1) throw new Error("missing plaintext framing byte")
    const body = plaintext.subarray(1)
    if (plaintext[0] === PLAINTEXT_RAW) return body
    if (plaintext[0] === PLAINTEXT_DEFLATE && this.options.decompressPayload !== undefined) {
      return this.options.decompressPayload(body)
    }
    throw new Error("unsupported plaintext framing")
  }

  #abort(
    key: string,
    peerId: string,
    channelId: string,
    live: LiveChannel,
    reason: ChannelCloseReason
  ): void {
    this.#channels.delete(key)
    const seq = live.nextSendSeq
    live.nextSendSeq += 1
    this.options.sendEnvelope(peerId, { t: "close", channelId, seq, reason })
    notifyClosed(live, reason)
  }

  #refuse(peerId: string, channelId: string, reason: ChannelCloseReason): void {
    this.options.sendEnvelope(peerId, { t: "close", channelId, seq: 0, reason })
  }
}
