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
  gatewayChannelHandler,
  type ChannelHandler
} from "@codevisor/cloud-client"
import { WebSocket } from "ws"

/// The machine ends of the generic http/ws relay channels: replay sealed
/// requests against this server's own loopback API and bridge sealed ws
/// channels onto its own ws endpoints. Integration glue over `fetch` and
/// `ws` — the frame/header/credit logic it composes is fully covered in
/// @codevisor/cloud-client (cloud-proxy.ts, incoming-channel.ts).

/// A request body fed by sealed chunk frames. Credit for a chunk is granted
/// only when fetch pulls it, so the opener can never get more than its
/// credit window ahead of the local server's consumption: a 500MB upload
/// holds about PROXY_INITIAL_CREDIT_BYTES here, whatever its size.
export const streamedRequestBody = (grantCredit: (sealedBytes: number) => void) => {
  const queued: Array<{ readonly data: Uint8Array; readonly sealedBytes: number }> = []
  let ended = false
  let failure: Error | undefined
  let wake: (() => void) | undefined
  const notify = (): void => {
    const resume = wake
    wake = undefined
    resume?.()
  }
  const stream = new ReadableStream<Uint8Array>(
    {
      pull: async (controller) => {
        while (queued.length === 0 && !ended && failure === undefined) {
          await new Promise<void>((resolve) => (wake = resolve))
        }
        if (failure !== undefined) {
          controller.error(failure)
          return
        }
        const next = queued.shift()
        if (next === undefined) {
          controller.close()
          return
        }
        controller.enqueue(next.data)
        grantCredit(next.sealedBytes)
      },
      cancel: () => {
        // The local server answered without reading the rest (e.g. 413);
        // later chunks are dropped by the handler.
        queued.length = 0
        ended = true
      }
    },
    { highWaterMark: 0 }
  )
  return {
    stream,
    push: (data: Uint8Array, sealedBytes: number): void => {
      if (ended || failure !== undefined) return
      queued.push({ data, sealedBytes })
      notify()
    },
    end: (): void => {
      ended = true
      notify()
    },
    fail: (cause: Error): void => {
      if (ended && queued.length === 0) return
      failure = cause
      queued.length = 0
      notify()
    }
  }
}

/// Serves one app-opened HTTP channel: replay the sealed request against the
/// local server (loopback is exempt from token auth, so the app's cloud
/// bearer is stripped and never forwarded), then stream the response back as
/// head/chunk/end frames.
///
/// On flow-controlled opens both directions are credit-paced. A request body
/// streams into the local fetch as its chunks arrive (streamedRequestBody),
/// and reading the response pauses while the send queue sits behind the
/// app's credit window, so large uploads and downloads never balloon memory
/// on this hop (or the hub's). Openers without flow control cannot be paced,
/// so their bodies are buffered up to MAX_REQUEST_BODY_BYTES. Pure frame and
/// header logic lives in cloud-proxy.ts.
export const httpChannelHandler =
  (localBaseUrl: string, log: (line: string) => void): ChannelHandler =>
  (channel) => {
    const params = parseHttpChannelParams(channel.params)
    if (params === undefined) {
      channel.close("rejected")
      return
    }
    const flowControlled = channel.flowControlRequested
    const buffered = emptyBodyBuffer()
    let streamed: ReturnType<typeof streamedRequestBody> | undefined
    const abort = new AbortController()
    let requestDone = false
    let channelClosed = false
    let releaseDrain: (() => void) | undefined
    channel.onClosed = () => {
      channelClosed = true
      streamed?.fail(new Error("Cloud http channel closed before the request body ended"))
      abort.abort()
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
    const reject = (): void => {
      requestDone = true
      streamed?.fail(new Error("Cloud http channel request was rejected"))
      abort.abort()
      channel.close("rejected")
    }
    const respond = async (
      body: Uint8Array<ArrayBuffer> | ReadableStream<Uint8Array>
    ): Promise<void> => {
      try {
        const response = await fetch(localBaseUrl + params.path, {
          method: params.method,
          headers: sanitizeRequestHeaders(params.headers),
          signal: abort.signal,
          ...(body instanceof ReadableStream
            ? { body, duplex: "half" as const }
            : body.byteLength === 0
              ? {}
              : { body })
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
        requestDone = true
        channel.send({ kind: "end" })
        // Queued frames flush as credit arrives; the close follows them.
        channel.close("done")
      } catch (cause) {
        if (channelClosed) return
        log(`Cloud http channel failed: ${cause instanceof Error ? cause.message : String(cause)}`)
        channel.close("rejected")
      }
    }
    channel.onData = (value, sealedBytes) => {
      if (requestDone) return
      const frame = parseHttpRequestFrame(value)
      if (frame === undefined) {
        reject()
        return
      }
      if (frame.kind === "end") {
        requestDone = true
        if (streamed === undefined) void respond(concatBodyBuffer(buffered))
        else streamed.end()
        return
      }
      if (flowControlled) {
        // The first chunk starts the local request; the rest stream into it.
        if (streamed === undefined) {
          streamed = streamedRequestBody((bytes) => {
            if (!channelClosed) channel.grantCredit(bytes)
          })
          void respond(streamed.stream)
        }
        streamed.push(frame.data, sealedBytes)
        return
      }
      if (!appendBodyChunk(buffered, frame.data)) reject()
    }
  }

/// Serves gateway channels (other machines' Codevisor gateway calls, see
/// @codevisor/cloud-client gateway-channel.ts) by replaying each request
/// against this server's own POST /v1/gateway/invoke — the only route this
/// channel type can reach, so a peer machine gets exactly the gateway and
/// nothing else of the local API. Cancelling the channel aborts the fetch,
/// which the route turns into an aborted gateway call.
export const gatewayLoopbackHandler = (
  localBaseUrl: string,
  log: (line: string) => void
): ChannelHandler =>
  gatewayChannelHandler(async (request, signal) => {
    const response = await fetch(`${localBaseUrl}/v1/gateway/invoke`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: request,
      signal
    })
    return { status: response.status, body: await response.text() }
  }, log)

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
