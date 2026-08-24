import type { ChannelCloseReason, RelayFrameHeader } from "@codevisor/api"
import type { ChannelCipher } from "@codevisor/cloud-crypto"

/// An app-opened channel as seen by machine-side handlers. Payloads are
/// sealed/opened transparently; handlers only ever see plaintext values.
export interface IncomingChannel {
  channelId: string
  peerId: string
  channelType: string
  params: unknown
  /// The opener requested credit-based flow control in both directions (see
  /// ChannelOpenPayload.flowControl). Handlers on such channels MUST grant
  /// credit or the opener can never send; their structured sends queue until
  /// the opener grants budget (watch `queuedOutboundBytes`/`onOutboundDrain`
  /// to pause the local source).
  flowControlRequested: boolean
  send(value: unknown): void
  /// Sends opaque plaintext and returns the exact ciphertext budget consumed,
  /// or undefined if the channel is already closed. Never queues: raw-byte
  /// handlers (byte-stream) do their own credit accounting.
  sendBytes(value: Uint8Array): number | undefined
  /// Enables explicit receive-side flow control. Call synchronously from the
  /// channel handler before granting any credit or receiving byte frames.
  /// Implied when the opener requested flow control.
  deferInboundCredit(): void
  /// Allows the peer to send this many ciphertext bytes.
  grantCredit(bytes: number): void
  /// Plaintext bytes queued behind the peer's credit window by `send`.
  /// Always 0 on channels without opener-requested flow control.
  queuedOutboundBytes(): number
  close(reason: ChannelCloseReason): void
  onData: ((value: unknown, sealedBytes: number) => void) | null
  onBytes: ((value: Uint8Array, sealedBytes: number) => void) | null
  onCredit: ((bytes: number) => void) | null
  /// Fires when a credit-gated send queue empties — resume the local source.
  onOutboundDrain: (() => void) | null
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
  /// Credits the peer's send budget and flushes any queued structured sends.
  /// Returns false for an invalid grant (the receiver aborts the channel).
  receiveCredit: (bytes: number) => boolean
}

/// Framing byte for negotiated-compression channels: the plaintext body
/// follows as-is.
export const PLAINTEXT_RAW = 0
/// Framing byte for negotiated-compression channels: the body is raw-DEFLATE
/// compressed (node deflateRaw / Apple COMPRESSION_ZLIB — no zlib header).
export const PLAINTEXT_DEFLATE = 1

/// ChaCha20-Poly1305 appends a 16-byte tag; sealed cost is plaintext + tag.
export const SEALED_OVERHEAD_BYTES = 16

export interface LiveChannelPort {
  channelId: string
  peerId: string
  channelType: string
  params: unknown
  cipher: ChannelCipher
  /// Whether the opener negotiated prefix-framed (compressible) payloads.
  compressed: boolean
  /// Whether the opener requested credit-based flow control both ways.
  flowControl: boolean
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
  /// Final plaintext for one structured value (framing already applied on
  /// negotiated-compression channels), so its sealed cost is known before a
  /// seq is allocated: cost = body + tag.
  const encodeBody = (value: unknown): Uint8Array => {
    const json = utf8Encoder.encode(JSON.stringify(value))
    return port.compressed ? framePlaintext(json) : json
  }
  /// Credit-gated structured sends queue here until the opener grants budget.
  const outboundQueue: Uint8Array[] = []
  let queuedBytes = 0
  let pendingCloseReason: ChannelCloseReason | undefined
  const sealAndSend = (live: LiveChannel, body: Uint8Array): void => {
    const seq = live.nextSendSeq
    live.nextSendSeq += 1
    port.sendEnvelope(
      { t: "data", channelId, seq },
      live.cipher.seal(channelId, "responder-to-opener", seq, body)
    )
  }
  const sendClose = (live: LiveChannel, reason: ChannelCloseReason): void => {
    port.remove()
    port.sendEnvelope({ t: "close", channelId, seq: live.nextSendSeq, reason })
  }
  /// Sends queued bodies while credit allows; a drained queue releases any
  /// deferred close and tells the handler to resume its source.
  const flushOutbound = (live: LiveChannel): void => {
    if (!port.ready()) return
    while (outboundQueue.length > 0) {
      const body = outboundQueue[0]!
      if (body.byteLength + SEALED_OVERHEAD_BYTES > outboundCredit) return
      outboundQueue.shift()
      queuedBytes -= body.byteLength
      outboundCredit -= body.byteLength + SEALED_OVERHEAD_BYTES
      sealAndSend(live, body)
    }
    if (pendingCloseReason !== undefined) {
      sendClose(live, pendingCloseReason)
      return
    }
    live.channel.onOutboundDrain?.()
  }
  let outboundCredit = 0
  return {
    cipher,
    nextReceiveSeq: 1,
    nextSendSeq: 0,
    flowControlled: port.flowControl,
    inboundCredit: 0,
    compressed: port.compressed,
    receiveCredit: (bytes) => {
      const live = port.current()
      if (live === undefined) return true
      if (
        !Number.isSafeInteger(bytes) ||
        bytes <= 0 ||
        outboundCredit > Number.MAX_SAFE_INTEGER - bytes
      ) {
        return false
      }
      outboundCredit += bytes
      if (port.flowControl) flushOutbound(live)
      live.channel.onCredit?.(bytes)
      return true
    },
    channel: {
      channelId,
      peerId: port.peerId,
      channelType: port.channelType,
      params: port.params,
      flowControlRequested: port.flowControl,
      send: (value) => {
        const current = port.current()
        if (current === undefined || !port.ready() || pendingCloseReason !== undefined) return
        const body = encodeBody(value)
        if (port.flowControl) {
          if (
            outboundQueue.length > 0 ||
            body.byteLength + SEALED_OVERHEAD_BYTES > outboundCredit
          ) {
            outboundQueue.push(body)
            queuedBytes += body.byteLength
            return
          }
          outboundCredit -= body.byteLength + SEALED_OVERHEAD_BYTES
        }
        sealAndSend(current, body)
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
      queuedOutboundBytes: () => queuedBytes,
      close: (reason) => {
        const current = port.current()
        if (current === undefined) return
        if (outboundQueue.length > 0 && port.ready()) {
          // Data already accepted for send must not be jumped by the close —
          // it goes out as credit arrives, then the close follows.
          pendingCloseReason ??= reason
          return
        }
        sendClose(current, reason)
      },
      onData: null,
      onBytes: null,
      onCredit: null,
      onOutboundDrain: null,
      onClosed: null
    }
  }
}
