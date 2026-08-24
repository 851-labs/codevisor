import type { ChannelCloseReason, RelayFrameHeader } from "@codevisor/api"
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

/// The responder half of the sealed channel protocol, independent of the pipe
/// that delivers the frames. The hub relay connection is caller #1; a direct
/// LAN/tailnet listener can feed the same receiver — a channel neither knows
/// nor cares which pipe carried it. The owner routes decoded relay frames in
/// through `handleRelay` and gets outbound frames back through
/// `sendEnvelope`; channel lifetime is scoped to the owning pipe: when that
/// pipe dies, the owner calls `dropAll`.
export interface ChannelReceiverOptions {
  /// This machine's static X25519 secret key (base64url).
  secretKey: string
  /// Keyed by channelType (e.g. "terminal"). Unknown types are refused with
  /// close reason "unsupported".
  channelHandlers: Record<string, ChannelHandler>
  /// TOFU pin store for app-device keys. When provided, a channel open whose
  /// `peerPublicKey` conflicts with the pinned key for its `peerDeviceId` is
  /// refused ("rejected") — the pipe is not trusted for key continuity. Keys
  /// pin only after a successful open (proof the opener holds the matching
  /// secret); opens without a device id proceed unpinned.
  peerKeyPins?: PeerKeyPinStore
  /// Fired on every refused open so integrators can log the substitution
  /// attempt with enough detail to investigate.
  onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  /// Compresses an outgoing plaintext body on channels whose opener
  /// negotiated compressible framing; return undefined when not worthwhile.
  compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
  /// Inflates a DEFLATE-framed inbound body on negotiated channels. Absent =
  /// compressed inbound frames are refused (the app only compresses when the
  /// machine advertises support via this pair being wired up).
  decompressPayload?: (bytes: Uint8Array) => Uint8Array
  /// Queues one outbound relay frame toward the peer (empty payload for
  /// credit/close frames, whose parameters live in the header).
  sendEnvelope: (peerId: string, frame: RelayFrameHeader, payload?: Uint8Array) => void
  /// Whether the owning pipe can currently send.
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
    peerDeviceId: string | undefined
  ): void {
    const key = `${peerId}/${frame.channelId}`
    if (frame.t === "open") {
      this.#handleOpen(key, peerId, frame, payload, peerPublicKey, peerDeviceId)
      return
    }
    const live = this.#channels.get(key)
    if (live === undefined) {
      // A frame for a channel we don't know about — typically the app kept a
      // channel alive across our pipe reconnect (channel state is in-memory
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
    if (frame.seq !== live.nextReceiveSeq) {
      this.#abort(key, peerId, frame.channelId, live, "protocol-error")
      return
    }
    if (frame.t === "credit") {
      live.nextReceiveSeq += 1
      // Credits our send budget (flushing queued gated sends) before the
      // handler's own observer runs; an invalid grant kills the channel.
      if (!live.receiveCredit(frame.bytes)) {
        this.#abort(key, peerId, frame.channelId, live, "protocol-error")
      }
      return
    }
    // data — the monotonic seq contract is bound into the AAD.
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
    if (value instanceof Uint8Array) live.channel.onBytes?.(value, sealedBytes)
    else live.channel.onData?.(value, sealedBytes)
  }

  /// Tears down one peer's channels (the pipe reported the peer gone).
  dropPeer(peerId: string): void {
    for (const [key, live] of this.#channels) {
      if (key.startsWith(`${peerId}/`)) {
        this.#channels.delete(key)
        live.channel.onClosed?.("peer-gone")
      }
    }
  }

  /// Tears down every channel (the owning pipe died or is stopping).
  dropAll(reason: ChannelCloseReason | "peer-gone"): void {
    const channels = [...this.#channels.values()]
    this.#channels.clear()
    for (const live of channels) live.channel.onClosed?.(reason)
  }

  #handleOpen(
    key: string,
    peerId: string,
    frame: Extract<RelayFrameHeader, { t: "open" }>,
    payload: Uint8Array,
    peerPublicKey: string | undefined,
    peerDeviceId: string | undefined
  ): void {
    if (peerPublicKey === undefined || this.#channels.has(key)) {
      this.#refuse(peerId, frame.channelId, "protocol-error")
      return
    }
    // TOFU: a key that conflicts with the pin for this app device means the
    // pipe (or someone controlling it) substituted the opener's identity —
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
    let openPayload: {
      channelType?: unknown
      params?: unknown
      compress?: unknown
      flowControl?: unknown
    }
    try {
      cipher = acceptChannel(this.options.secretKey, peerPublicKey, frame.ephemeralKey)
      openPayload = openJson(cipher, frame.channelId, "opener-to-responder", 0, payload) as {
        channelType?: unknown
        params?: unknown
        compress?: unknown
        flowControl?: unknown
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
      // Opener-requested flow control: inbound enforcement starts strict and
      // structured sends gate on the opener's credit grants.
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
    handler(live.channel)
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

  #abort(
    key: string,
    peerId: string,
    channelId: string,
    live: LiveChannel,
    reason: ChannelCloseReason
  ): void {
    this.#channels.delete(key)
    this.#refuse(peerId, channelId, reason)
    live.channel.onClosed?.(reason)
  }

  #refuse(peerId: string, channelId: string, reason: ChannelCloseReason): void {
    this.options.sendEnvelope(peerId, { t: "close", channelId, seq: 0, reason })
  }
}
