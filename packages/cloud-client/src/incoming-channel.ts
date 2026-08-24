import type { ChannelCloseReason, RelayFrameHeader } from "@codevisor/api"
import { sealJson, type ChannelCipher } from "@codevisor/cloud-crypto"

/// An app-opened channel as seen by machine-side handlers. Payloads are
/// sealed/opened transparently; handlers only ever see plaintext values.
export interface IncomingChannel {
  channelId: string
  peerId: string
  channelType: string
  params: unknown
  send(value: unknown): void
  /// Sends opaque plaintext and returns the exact ciphertext budget consumed,
  /// or undefined if the channel is already closed.
  sendBytes(value: Uint8Array): number | undefined
  /// Enables explicit receive-side flow control. Call synchronously from the
  /// channel handler before granting any credit or receiving byte frames.
  deferInboundCredit(): void
  /// Allows the peer to send this many ciphertext bytes.
  grantCredit(bytes: number): void
  close(reason: ChannelCloseReason): void
  onData: ((value: unknown) => void) | null
  onBytes: ((value: Uint8Array, sealedBytes: number) => void) | null
  onCredit: ((bytes: number) => void) | null
  onClosed: ((reason: ChannelCloseReason | "peer-gone") => void) | null
}

export type ChannelHandler = (channel: IncomingChannel) => void

/// One accepted channel's live state on the machine connection: cipher,
/// per-direction seq counters, and the handler-facing channel surface.
export interface LiveChannel {
  cipher: ChannelCipher
  channel: IncomingChannel
  nextReceiveSeq: number
  nextSendSeq: number
  flowControlled: boolean
  inboundCredit: number
  /// The opener negotiated prefix-framed payloads (see PLAINTEXT_RAW): every
  /// data plaintext in both directions starts with a framing byte, and the
  /// responder may deflate bodies it deems worthwhile.
  compressed: boolean
}

/// Framing byte for negotiated-compression channels: the plaintext body
/// follows as-is.
export const PLAINTEXT_RAW = 0
/// Framing byte for negotiated-compression channels: the body is raw-DEFLATE
/// compressed (node deflateRaw / Apple COMPRESSION_ZLIB — no zlib header).
export const PLAINTEXT_DEFLATE = 1

export interface LiveChannelPort {
  channelId: string
  peerId: string
  channelType: string
  params: unknown
  cipher: ChannelCipher
  /// Whether the opener negotiated prefix-framed (compressible) payloads.
  compressed: boolean
  /// Compresses a plaintext body, or returns undefined when not worthwhile
  /// (too small, incompressible). Absent = never compress (prefix stays RAW).
  compress?: (bytes: Uint8Array) => Uint8Array | undefined
  /// The registered live record, while the channel is open. Every outbound
  /// operation re-reads it so a closed channel becomes a no-op.
  current: () => LiveChannel | undefined
  /// Unregisters the channel (self-initiated close).
  remove: () => void
  /// Whether the connection can currently send (its socket is attached).
  ready: () => boolean
  sendEnvelope: (frame: RelayFrameHeader, payload?: Uint8Array) => void
}

const utf8Encoder = new TextEncoder()

/// Builds the live record for an accepted channel, wiring its outbound
/// surface ((frame →) seal → envelope) to the owning connection via `port`.
export const makeLiveChannel = (port: LiveChannelPort): LiveChannel => {
  const { channelId, cipher } = port
  /// Applies the negotiated framing: attempt compression, prefix accordingly.
  const framePlaintext = (body: Uint8Array): Uint8Array => {
    const compressedBody = port.compress?.(body)
    const framed = new Uint8Array((compressedBody ?? body).byteLength + 1)
    framed[0] = compressedBody === undefined ? PLAINTEXT_RAW : PLAINTEXT_DEFLATE
    framed.set(compressedBody ?? body, 1)
    return framed
  }
  return {
    cipher,
    nextReceiveSeq: 1,
    nextSendSeq: 0,
    flowControlled: false,
    inboundCredit: 0,
    compressed: port.compressed,
    channel: {
      channelId,
      peerId: port.peerId,
      channelType: port.channelType,
      params: port.params,
      send: (value) => {
        const current = port.current()
        if (current === undefined || !port.ready()) return
        const seq = current.nextSendSeq
        current.nextSendSeq += 1
        if (!port.compressed) {
          port.sendEnvelope(
            { t: "data", channelId, seq },
            sealJson(current.cipher, channelId, "responder-to-opener", seq, value)
          )
          return
        }
        const body = framePlaintext(utf8Encoder.encode(JSON.stringify(value)))
        port.sendEnvelope(
          { t: "data", channelId, seq },
          current.cipher.seal(channelId, "responder-to-opener", seq, body)
        )
      },
      sendBytes: (value) => {
        const current = port.current()
        if (current === undefined || !port.ready()) return undefined
        const seq = current.nextSendSeq
        current.nextSendSeq += 1
        const box = current.cipher.seal(channelId, "responder-to-opener", seq, value)
        port.sendEnvelope({ t: "data", channelId, seq }, box)
        return box.byteLength
      },
      deferInboundCredit: () => {
        const current = port.current()
        if (current !== undefined) current.flowControlled = true
      },
      grantCredit: (bytes) => {
        const current = port.current()
        if (
          current === undefined ||
          !port.ready() ||
          !Number.isSafeInteger(bytes) ||
          bytes <= 0 ||
          current.inboundCredit > Number.MAX_SAFE_INTEGER - bytes
        ) {
          return
        }
        current.inboundCredit += bytes
        const seq = current.nextSendSeq
        current.nextSendSeq += 1
        port.sendEnvelope({ t: "credit", channelId, seq, bytes })
      },
      close: (reason) => {
        const current = port.current()
        if (current === undefined) return
        port.remove()
        port.sendEnvelope({ t: "close", channelId, seq: current.nextSendSeq, reason })
      },
      onData: null,
      onBytes: null,
      onCredit: null,
      onClosed: null
    }
  }
}
