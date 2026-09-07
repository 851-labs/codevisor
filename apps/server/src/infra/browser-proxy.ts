import { randomBytes, timingSafeEqual } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"
import { connect, type Socket } from "node:net"
import {
  forwardBrowserHTTP,
  forwardBrowserUpgrade,
  type BrowserForwardTarget
} from "./browser-forward-proxy.js"

export const browserProxyTarget = (authority: string | undefined) => {
  if (
    authority === undefined ||
    !/^(\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9_.-]+):[0-9]{1,5}$/.test(authority)
  ) {
    return undefined
  }
  const separator = authority.lastIndexOf(":")
  const port = Number(authority.slice(separator + 1))
  if (port < 1 || port > 65535) return undefined
  let host = authority
    .slice(0, separator)
    .replace(/^\[|\]$/g, "")
    .toLowerCase()
  const ipv4Alias = /^ipv4-(127)-(\d+)-(\d+)-(\d+)\.proxy\.localhost$/.exec(host)
  if (ipv4Alias !== null) {
    const parts = ipv4Alias.slice(1).map(Number)
    if (parts.some((part) => part > 255)) return undefined
    host = parts.join(".")
  } else if (host === "ipv6.proxy.localhost") host = "::1"
  else if (host === "localhost" || host.endsWith(".localhost")) host = "127.0.0.1"
  return { host, port }
}

/// A connection proxy, carried unchanged by the existing encrypted byte relay.
/// Credentials authorize proxy requests and never enter a destination's byte stream.
/// They live for this server process and are obtained through the authenticated API.
export class BrowserProxy {
  readonly session = {
    username: "codevisor-browser",
    password: randomBytes(32).toString("base64url")
  }
  private readonly authorization = Buffer.from(
    `Basic ${Buffer.from(`${this.session.username}:${this.session.password}`).toString("base64")}`
  )
  private readonly sockets = new Set<Socket>()
  private closed = false

  constructor(
    private readonly maximumConnections = 256,
    private readonly dial: (target: {
      host: string
      port: number
      allowHalfOpen: true
    }) => Socket = connect
  ) {}

  private authorized(request: IncomingMessage): boolean {
    const supplied = Buffer.from(request.headers["proxy-authorization"] ?? "")
    return (
      supplied.length === this.authorization.length && timingSafeEqual(supplied, this.authorization)
    )
  }

  private track = (socket: Socket): void => {
    if (this.sockets.has(socket)) return
    this.sockets.add(socket)
    socket.on("error", () => socket.destroy())
    socket.once("close", () => this.sockets.delete(socket))
  }

  private forwardTarget(request: IncomingMessage): BrowserForwardTarget | number {
    if (!this.authorized(request)) return 407
    let url: URL
    try {
      url = new URL(request.url ?? "")
    } catch {
      return 400
    }
    if (url.protocol !== "http:" || url.username || url.password || url.hash) return 400
    const target = browserProxyTarget(`${url.hostname}:${url.port || 80}`)
    if (!target) return 400
    if (target.port === request.socket.localPort) return 403
    if (this.closed || this.sockets.size >= this.maximumConnections * 2) return 503
    return { ...target, url }
  }

  handleHTTP(request: IncomingMessage, response: ServerResponse): void {
    const target = this.forwardTarget(request)
    if (typeof target === "number") {
      response
        .writeHead(target, {
          "Content-Length": "0",
          Connection: "close",
          ...(target === 407 ? { "Proxy-Authenticate": 'Basic realm="Codevisor browser"' } : {})
        })
        .end()
      return
    }
    forwardBrowserHTTP(request, response, target, this.track)
  }

  handleUpgrade(request: IncomingMessage, socket: Socket, head: Buffer): void {
    socket.on("error", () => socket.destroy())
    const target = this.forwardTarget(request)
    if (typeof target === "number") {
      socket.end(
        `HTTP/1.1 ${target} Proxy Request Rejected\r\nContent-Length: 0\r\nConnection: close\r\n${target === 407 ? 'Proxy-Authenticate: Basic realm="Codevisor browser"\r\n' : ""}\r\n`
      )
      return
    }
    forwardBrowserUpgrade(request, socket, head, target, this.track)
  }

  handleConnect(request: IncomingMessage, socket: Socket, head: Buffer): void {
    socket.on("error", () => socket.destroy())
    socket.setTimeout(15_000, () => socket.destroy())
    // CONNECT sockets bypass the ordinary HTTP request router, including its
    // loopback auth exemption. Require the browser capability on every connection.
    if (!this.authorized(request)) {
      socket.end(
        'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="Codevisor browser"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
      )
      return
    }
    const target = browserProxyTarget(request.url)
    if (target === undefined) {
      socket.end("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      return
    }
    // Never turn web content into a trusted loopback caller of our control API.
    // Block the listener port for all hosts, including DNS aliases and rebinding.
    if (target.port === request.socket.localPort) {
      socket.end("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      return
    }
    if (this.closed || this.sockets.size >= this.maximumConnections * 2) {
      socket.end(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )
      return
    }
    const upstream = this.dial({ ...target, allowHalfOpen: true })
    this.sockets.add(socket)
    this.sockets.add(upstream)
    let connected = false
    const fail = () => {
      upstream.destroy()
      if (connected) socket.destroy()
      else socket.end("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }
    upstream.setTimeout(15_000, fail)
    upstream.on("error", fail)
    socket.on("error", () => upstream.destroy())
    socket.on("close", () => {
      this.sockets.delete(socket)
      upstream.destroy()
    })
    upstream.on("close", () => {
      this.sockets.delete(upstream)
      if (connected) socket.destroy()
    })
    upstream.on("connect", () => {
      connected = true
      upstream.setTimeout(0)
      socket.setTimeout(0)
      socket.setNoDelay(true)
      upstream.setNoDelay(true)
      socket.write("HTTP/1.1 200 Connection Established\r\n\r\n")
      if (head.length > 0) upstream.write(head)
      socket.pipe(upstream)
      upstream.pipe(socket)
    })
  }

  close(): void {
    this.closed = true
    for (const socket of this.sockets) socket.destroy()
    this.sockets.clear()
  }
}
