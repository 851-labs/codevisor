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

export const wsChannelHandler =
  (localBaseUrl: string): ChannelHandler =>
  (channel) => {
    const params = parseWsChannelParams(channel.params)
    if (params === undefined) {
      channel.close("rejected")
      return
    }
    const flowControlled = channel.flowControlRequested
    let socket: WebSocket
    try {
      socket = new WebSocket(localBaseUrl.replace(/^http/, "ws") + params.path)
    } catch {
      channel.close("rejected")
      return
    }
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
      for (const frame of encodeWsFrames(isBinary ? new Uint8Array(bytes) : String(data))) {
        channel.send(frame)
      }
      if (flowControlled && channel.queuedOutboundBytes() > PROXY_OUTBOUND_HIGH_WATER_BYTES) {
        socket.pause()
      }
    })
    channel.onOutboundDrain = () => {
      if (flowControlled && socket.isPaused) socket.resume()
    }
    socket.on("close", () => channel.close("done"))
    socket.on("error", () => {
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
