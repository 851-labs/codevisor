import {
  appendBodyChunk,
  chunkFrames,
  concatBodyBuffer,
  emptyBodyBuffer,
  encodeWsFrames,
  headFrame,
  parseHttpChannelParams,
  parseHttpRequestFrame,
  parseWsChannelParams,
  parseWsFrame,
  PROXY_INITIAL_CREDIT_BYTES,
  PROXY_OUTBOUND_HIGH_WATER_BYTES,
  sanitizeRequestHeaders,
  type ChannelHandler
} from "@codevisor/cloud-client"
import { WebSocket } from "ws"

/// The machine ends of the generic http/ws relay channels: replay sealed
/// requests against this server's own loopback API and bridge sealed ws
/// channels onto its own ws endpoints. Integration glue over `fetch` and
/// `ws` — the frame/header/credit logic it composes is fully covered in
/// @codevisor/cloud-client (cloud-proxy.ts, incoming-channel.ts).

/// Serves one app-opened HTTP channel: buffer the sealed request body frames,
/// replay the request against the local server (loopback is exempt from token
/// auth, so the app's cloud bearer is stripped and never forwarded), then
/// stream the response back as head/chunk/end frames. On flow-controlled
/// opens the response is credit-paced: reading from the local server pauses
/// while the send queue sits behind the app's credit window, so a 32MB body
/// never balloons memory on this hop (or the hub's). Pure frame and header
/// logic lives in cloud-proxy.ts.
export const httpChannelHandler =
  (localBaseUrl: string, log: (line: string) => void): ChannelHandler =>
  (channel) => {
    const params = parseHttpChannelParams(channel.params)
    if (params === undefined) {
      channel.close("rejected")
      return
    }
    const flowControlled = channel.flowControlRequested
    const body = emptyBodyBuffer()
    let requestDone = false
    let channelClosed = false
    let releaseDrain: (() => void) | undefined
    channel.onClosed = () => {
      channelClosed = true
      releaseDrain?.()
    }
    channel.onOutboundDrain = () => releaseDrain?.()
    /// Resolves once the gated send queue has drained (or the channel died).
    const drained = (): Promise<void> =>
      new Promise((resolve) => {
        if (channelClosed || channel.queuedOutboundBytes() === 0) {
          resolve()
          return
        }
        releaseDrain = () => {
          releaseDrain = undefined
          resolve()
        }
      })
    if (flowControlled) channel.grantCredit(PROXY_INITIAL_CREDIT_BYTES)
    const respond = async (): Promise<void> => {
      try {
        const bytes = concatBodyBuffer(body)
        const response = await fetch(localBaseUrl + params.path, {
          method: params.method,
          headers: sanitizeRequestHeaders(params.headers),
          ...(bytes.byteLength === 0 ? {} : { body: bytes })
        })
        if (channelClosed) {
          await response.body?.cancel()
          return
        }
        channel.send(headFrame(response.status, response.headers))
        const reader = response.body?.getReader()
        if (reader !== undefined) {
          for (;;) {
            const { done, value } = await reader.read()
            if (done) break
            if (channelClosed) {
              await reader.cancel()
              return
            }
            for (const frame of chunkFrames(value)) channel.send(frame)
            if (channel.queuedOutboundBytes() > PROXY_OUTBOUND_HIGH_WATER_BYTES) await drained()
            if (channelClosed) {
              await reader.cancel()
              return
            }
          }
        }
        channel.send({ kind: "end" })
        // Queued frames flush as credit arrives; the close follows them.
        channel.close("done")
      } catch (cause) {
        log(`Cloud http channel failed: ${cause instanceof Error ? cause.message : String(cause)}`)
        channel.close("rejected")
      }
    }
    channel.onData = (value, sealedBytes) => {
      if (requestDone) return
      const frame = parseHttpRequestFrame(value)
      if (frame === undefined) {
        requestDone = true
        channel.close("rejected")
        return
      }
      if (frame.kind === "chunk") {
        if (!appendBodyChunk(body, frame.data)) {
          requestDone = true
          channel.close("rejected")
        } else if (flowControlled) {
          // The chunk is buffered (bounded by MAX_REQUEST_BODY_BYTES), so the
          // upload window replenishes immediately.
          channel.grantCredit(sealedBytes)
        }
        return
      }
      requestDone = true
      void respond()
    }
  }

/// Serves one app-opened WebSocket channel by bridging it onto the local
/// server's own WS endpoint. Frames arriving before the local socket opens
/// are queued; either side closing gracefully surfaces as close("done"). On
/// flow-controlled opens both directions are credit-paced: the local socket
/// pauses while outbound frames sit behind the app's window, and the app's
/// window replenishes only after the local socket accepts each frame.
export const wsChannelHandler =
  (localBaseUrl: string): ChannelHandler =>
  (channel) => {
    const params = parseWsChannelParams(channel.params)
    if (params === undefined) {
      channel.close("rejected")
      return
    }
    const flowControlled = channel.flowControlRequested
    const socket = new WebSocket(localBaseUrl.replace(/^http/, "ws") + params.path)
    let opened = false
    const queued: { data: string | Uint8Array; sealedBytes: number }[] = []
    const deliver = (data: string | Uint8Array, sealedBytes: number): void => {
      socket.send(data, (error) => {
        if (flowControlled && error === undefined) channel.grantCredit(sealedBytes)
      })
    }
    socket.on("open", () => {
      opened = true
      for (const message of queued) deliver(message.data, message.sealedBytes)
      queued.length = 0
    })
    socket.on("message", (data, isBinary) => {
      const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer)
      // Chunked: an oversized message (a huge tool-call event) would exceed
      // the hub's relay frame cap, and the dropped frame's seq gap would
      // abort the channel — with cursor replay resending the same oversized
      // event forever. Split frames reassemble on the app side instead.
      for (const frame of encodeWsFrames(isBinary ? new Uint8Array(bytes) : String(data))) {
        channel.send(frame)
      }
      // Gated sends queue behind the app's credit; pause the local socket so
      // a slow phone stalls this stream instead of growing the queue.
      if (flowControlled && channel.queuedOutboundBytes() > PROXY_OUTBOUND_HIGH_WATER_BYTES) {
        socket.pause()
      }
    })
    channel.onOutboundDrain = () => {
      if (flowControlled && socket.isPaused) socket.resume()
    }
    socket.on("close", () => channel.close("done"))
    socket.on("error", () => {
      // close fires afterwards; before open that would report "done" for a
      // websocket that never connected, so reject first (later closes no-op).
      if (!opened) channel.close("rejected")
    })
    if (flowControlled) channel.grantCredit(PROXY_INITIAL_CREDIT_BYTES)
    channel.onData = (value, sealedBytes) => {
      const frame = parseWsFrame(value)
      if (frame === undefined) {
        channel.close("protocol-error")
        socket.close()
        return
      }
      if (opened) deliver(frame.data, sealedBytes)
      else queued.push({ data: frame.data, sealedBytes })
    }
    channel.onClosed = () => socket.close()
  }
