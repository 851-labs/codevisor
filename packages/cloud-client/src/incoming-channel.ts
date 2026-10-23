import type { ChannelCloseReason, RelayFrameHeader } from "@codevisor/api"
import type { ChannelCipher } from "@codevisor/cloud-crypto"

export interface ChannelPeer {
  readonly deviceId?: string
  readonly publicKey: string
}

export interface IncomingChannel {
  channelId: string
  peerId: string
  peer: ChannelPeer
  channelType: string
  params: unknown
  flowControlRequested: boolean
  send(value: unknown): void
  sendBytes(value: Uint8Array): number | undefined
  deferInboundCredit(): void
  grantCredit(bytes: number): void
  queuedOutboundBytes(): number
  close(reason: ChannelCloseReason): void
  onData: ((value: unknown, sealedBytes: number) => void) | null
  onBytes: ((value: Uint8Array, sealedBytes: number) => void) | null
  onCredit: ((bytes: number) => void) | null
  onOutboundDrain: (() => void) | null
  onClosed: ((reason: ChannelCloseReason | "peer-gone") => void) | null
}

export type ChannelHandler = (channel: IncomingChannel) => void

export interface LiveChannel {
  cipher: ChannelCipher
  channel: IncomingChannel
  nextReceiveSeq: number
  nextSendSeq: number
  flowControlled: boolean
  inboundCredit: number
  compressed: boolean
  receiveCredit: (bytes: number) => boolean
}

export const PLAINTEXT_RAW = 0
export const PLAINTEXT_DEFLATE = 1

export const SEALED_OVERHEAD_BYTES = 16

export interface LiveChannelPort {
  channelId: string
  peerId: string
  peer: ChannelPeer
  channelType: string
  params: unknown
  cipher: ChannelCipher
  compressed: boolean
  flowControl: boolean
  compress?: (bytes: Uint8Array) => Uint8Array | undefined
  current: () => LiveChannel | undefined
  remove: () => void
  ready: () => boolean
  sendEnvelope: (frame: RelayFrameHeader, payload?: Uint8Array) => void
}

const utf8Encoder = new TextEncoder()

export const makeLiveChannel = (port: LiveChannelPort): LiveChannel => {
  const { channelId, cipher } = port
  const framePlaintext = (body: Uint8Array): Uint8Array => {
    const compressedBody = port.compress?.(body)
    const framed = new Uint8Array((compressedBody ?? body).byteLength + 1)
    framed[0] = compressedBody === undefined ? PLAINTEXT_RAW : PLAINTEXT_DEFLATE
    framed.set(compressedBody ?? body, 1)
    return framed
  }
  const encodeBody = (value: unknown): Uint8Array => {
    const json = utf8Encoder.encode(JSON.stringify(value))
    return port.compressed ? framePlaintext(json) : json
  }
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
      peer: port.peer,
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
