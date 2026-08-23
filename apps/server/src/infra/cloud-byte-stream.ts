import { connect, type Socket } from "node:net"
import {
  BYTE_STREAM_INITIAL_CREDIT_BYTES,
  BYTE_STREAM_MAX_CHUNK_BYTES,
  byteStreamSealedBytes,
  parseByteStreamChannelParams,
  type ChannelHandler
} from "@codevisor/cloud-client"

type DialLoopback = (options: { host: string; port: number; allowHalfOpen: true }) => Socket

const loopbackTarget = (localBaseUrl: string): { host: string; port: number } | undefined => {
  let url: URL
  try {
    url = new URL(localBaseUrl)
  } catch {
    return undefined
  }
  if (url.protocol !== "http:" || url.username !== "" || url.password !== "") return undefined
  const host = url.hostname === "[::1]" ? "::1" : url.hostname
  if (host !== "127.0.0.1" && host !== "::1" && host !== "localhost") return undefined
  const port = url.port === "" ? 80 : Number(url.port)
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) return undefined
  return { host, port }
}

/// Bridges one encrypted relay byte stream onto this Codevisor server's own
/// loopback TCP listener. The open payload selects only the fixed service;
/// clients cannot turn the relay into an arbitrary host/port proxy.
export const byteStreamChannelHandler = (
  localBaseUrl: string,
  log: (line: string) => void,
  dial: DialLoopback = (options) => connect(options)
): ChannelHandler => {
  const target = loopbackTarget(localBaseUrl)
  return (channel) => {
    if (target === undefined || parseByteStreamChannelParams(channel.params) === undefined) {
      channel.close("rejected")
      return
    }

    channel.deferInboundCredit()
    const socket = dial({ ...target, allowHalfOpen: true })
    socket.pause()

    let relayClosed = false
    let localEnded = false
    let finSent = false
    let peerEnded = false
    let outboundCredit = 0
    const outbound: Uint8Array[] = []

    const closeRelay = (reason: "done" | "rejected" | "protocol-error"): void => {
      if (relayClosed) return
      relayClosed = true
      channel.close(reason)
    }

    const flush = (): void => {
      if (relayClosed) return
      while (outbound.length > 0) {
        const next = outbound[0]!
        const expectedCost = byteStreamSealedBytes(next.byteLength)
        if (expectedCost > outboundCredit) return
        outbound.shift()
        const actualCost = channel.sendBytes(next)
        if (actualCost === undefined) {
          relayClosed = true
          socket.destroy()
          return
        }
        if (actualCost !== expectedCost) {
          closeRelay("protocol-error")
          socket.destroy()
          return
        }
        outboundCredit -= actualCost
      }
      if (localEnded && !finSent) {
        const finCost = byteStreamSealedBytes(0)
        if (finCost > outboundCredit) return
        const actualCost = channel.sendBytes(new Uint8Array())
        if (actualCost === undefined) {
          relayClosed = true
          socket.destroy()
          return
        }
        finSent = true
        outboundCredit -= actualCost
        return
      }
      socket.resume()
    }

    channel.onCredit = (bytes) => {
      if (outboundCredit > Number.MAX_SAFE_INTEGER - bytes) {
        closeRelay("protocol-error")
        socket.destroy()
        return
      }
      outboundCredit += bytes
      flush()
    }
    channel.onBytes = (bytes, sealedBytes) => {
      if (peerEnded || sealedBytes !== byteStreamSealedBytes(bytes.byteLength)) {
        closeRelay("protocol-error")
        socket.destroy()
        return
      }
      if (bytes.byteLength === 0) {
        peerEnded = true
        socket.end(() => channel.grantCredit(sealedBytes))
        return
      }
      socket.write(bytes, (error) => {
        if (error) {
          closeRelay("rejected")
          socket.destroy()
        } else {
          channel.grantCredit(sealedBytes)
        }
      })
    }
    channel.onClosed = () => {
      relayClosed = true
      socket.destroy()
    }

    socket.on("connect", () => {
      if (relayClosed) return
      channel.grantCredit(BYTE_STREAM_INITIAL_CREDIT_BYTES)
      flush()
    })
    socket.on("data", (data) => {
      socket.pause()
      const bytes = typeof data === "string" ? Buffer.from(data) : data
      for (let offset = 0; offset < bytes.byteLength; offset += BYTE_STREAM_MAX_CHUNK_BYTES) {
        outbound.push(bytes.subarray(offset, offset + BYTE_STREAM_MAX_CHUNK_BYTES))
      }
      flush()
    })
    socket.on("end", () => {
      localEnded = true
      flush()
    })
    socket.on("error", (cause) => {
      log(`Cloud byte stream failed: ${cause.message}`)
      closeRelay("rejected")
      socket.destroy()
    })
    socket.on("close", (hadError) => closeRelay(hadError ? "rejected" : "done"))
  }
}
