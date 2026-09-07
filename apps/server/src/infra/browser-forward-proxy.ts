import {
  request as httpRequest,
  type IncomingHttpHeaders,
  type IncomingMessage,
  type ServerResponse
} from "node:http"
import { connect, type Socket } from "node:net"

export const isBrowserProxyRequest = (request: IncomingMessage) =>
  request.url !== undefined && !request.url.startsWith("/") && request.url !== "*"

export function browserForwardHeaders(headers: IncomingHttpHeaders) {
  const excluded = new Set([
    "connection",
    "proxy-connection",
    "proxy-authorization",
    "proxy-authenticate",
    "keep-alive",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    ...(headers.connection ?? "")
      .toLowerCase()
      .split(",")
      .map((name) => name.trim())
  ])
  return Object.fromEntries(Object.entries(headers).filter(([name]) => !excluded.has(name)))
}

export interface BrowserForwardTarget {
  url: URL
  host: string
  port: number
}

export function forwardBrowserHTTP(
  request: IncomingMessage,
  response: ServerResponse,
  target: BrowserForwardTarget,
  track: (socket: Socket) => void
): void {
  const upstream = httpRequest({
    hostname: target.host,
    port: target.port,
    method: request.method,
    path: target.url.pathname + target.url.search,
    headers: { ...browserForwardHeaders(request.headers), host: target.url.host },
    agent: false
  })
  track(request.socket)
  upstream.once("socket", (socket) => {
    track(socket)
    socket.setTimeout(15_000, () => upstream.destroy(new Error("Proxy connection timed out")))
    socket.once("connect", () => socket.setTimeout(0))
  })
  const cancel = () => upstream.destroy()
  request.once("aborted", cancel)
  response.once("close", () => {
    request.off("aborted", cancel)
    if (!response.writableFinished) cancel()
  })
  upstream.on("error", () => {
    if (response.headersSent) response.destroy()
    else response.writeHead(502, { "Content-Length": "0", Connection: "close" }).end()
  })
  upstream.once("response", (incoming) => {
    response.writeHead(incoming.statusCode ?? 502, browserForwardHeaders(incoming.headers))
    incoming.on("error", () => response.destroy())
    incoming.pipe(response)
  })
  request.pipe(upstream)
}

export function forwardBrowserUpgrade(
  request: IncomingMessage,
  socket: Socket,
  head: Buffer,
  target: BrowserForwardTarget,
  track: (socket: Socket) => void
): void {
  const upstream = connect({ host: target.host, port: target.port, allowHalfOpen: true })
  track(socket)
  track(upstream)
  let connected = false
  const fail = () => {
    upstream.destroy()
    if (connected) socket.destroy()
    else socket.end("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  }
  upstream.setTimeout(15_000, fail)
  upstream.on("error", fail)
  socket.on("error", () => upstream.destroy())
  socket.once("close", () => upstream.destroy())
  upstream.once("close", () => {
    if (!upstream.readableEnded && connected) socket.destroy()
  })
  upstream.once("connect", () => {
    connected = true
    upstream.setTimeout(0)
    socket.setNoDelay(true)
    upstream.setNoDelay(true)
    const headers = {
      ...browserForwardHeaders(request.headers),
      host: target.url.host,
      connection: "Upgrade",
      upgrade: request.headers.upgrade
    }
    let opening = `${request.method} ${target.url.pathname}${target.url.search} HTTP/1.1\r\n`
    for (const [name, value] of Object.entries(headers)) {
      for (const item of Array.isArray(value) ? value : value === undefined ? [] : [value]) {
        opening += `${name}: ${item}\r\n`
      }
    }
    upstream.write(opening + "\r\n")
    if (head.length) upstream.write(head)
    socket.pipe(upstream)
    upstream.pipe(socket)
  })
}
