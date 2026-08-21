import type { IncomingMessage, ServerResponse } from "node:http"
import { request as httpRequest } from "node:http"
import { connect } from "node:net"
import type { Socket } from "node:net"

/// End-to-end headers only cross the proxy. Authorization is stripped in both
/// directions on purpose: the machine bearer token must never reach a plugin
/// process, mirroring the cloud relay's sanitizeRequestHeaders.
const HOP_BY_HOP_REQUEST_HEADERS = new Set([
  "authorization",
  "connection",
  "host",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade"
])

/// transfer-encoding is stripped because Node re-frames the piped body
/// itself; forwarding the plugin's framing header would corrupt responses.
const HOP_BY_HOP_RESPONSE_HEADERS = new Set(["connection", "keep-alive", "transfer-encoding"])

export interface ForwardHttpOptions {
  readonly port: number
  /// Path + query to request from the plugin server.
  readonly targetPath: string
  readonly request: IncomingMessage
  readonly response: ServerResponse
  /// Extra request headers (X-Codevisor-Context and its signature).
  readonly contextHeaders: Readonly<Record<string, string>>
  /// Cookie header override with the pane-session cookie stripped.
  readonly cookieHeader: string | undefined
  /// Set-Cookie issued on the initial token-exchange navigation.
  readonly setCookie?: string | undefined
  readonly timeoutMs: number
}

/// How a forwarded request ended, so the caller can feed the supervisor:
/// `ok` resets the crash accounting, `unreachable` means the plugin's
/// port is dead (kick the runtime so supervision relaunches it), `timeout`
/// means the process is alive but hung (no kick).
export type ForwardHttpOutcome = "ok" | "timeout" | "unreachable"

/// Streams one HTTP request through to the plugin's loopback server. The
/// plugin being down or hung must surface as a structured error response the
/// pane error card understands — never a socket hang-up.
export const forwardHttp = (options: ForwardHttpOptions): Promise<ForwardHttpOutcome> =>
  new Promise((resolve) => {
    const headers: Record<string, string | Array<string>> = {}
    for (const [name, value] of Object.entries(options.request.headers)) {
      if (value === undefined || HOP_BY_HOP_REQUEST_HEADERS.has(name) || name === "cookie") {
        continue
      }
      headers[name] = value
    }
    if (options.cookieHeader !== undefined) {
      headers["cookie"] = options.cookieHeader
    }
    for (const [name, value] of Object.entries(options.contextHeaders)) {
      headers[name] = value
    }
    const upstream = httpRequest({
      headers,
      host: "127.0.0.1",
      method: options.request.method,
      path: options.targetPath,
      port: options.port
    })
    const failWith = (
      outcome: Exclude<ForwardHttpOutcome, "ok">,
      status: number,
      message: string
    ): void => {
      upstream.destroy()
      /* v8 ignore next 4 -- a failure after headers are sent can only truncate the stream. */
      if (options.response.headersSent) {
        options.response.end()
        resolve(outcome)
        return
      }
      options.response.writeHead(status, { "Content-Type": "application/json" })
      options.response.end(JSON.stringify({ code: "pluginUnreachable", error: message }))
      resolve(outcome)
    }
    upstream.setTimeout(options.timeoutMs, () => {
      failWith("timeout", 504, `Plugin did not respond within ${options.timeoutMs}ms`)
    })
    upstream.on("error", (cause) => {
      failWith("unreachable", 502, `Plugin request failed: ${cause.message}`)
    })
    upstream.on("response", (pluginResponse) => {
      const responseHeaders: Record<string, string | Array<string>> = {}
      for (const [name, value] of Object.entries(pluginResponse.headers)) {
        if (value === undefined || HOP_BY_HOP_RESPONSE_HEADERS.has(name)) {
          continue
        }
        responseHeaders[name] = value
      }
      if (options.setCookie !== undefined) {
        // Node normalizes repeated set-cookie response headers into an array.
        const existing = responseHeaders["set-cookie"]
        const existingList = Array.isArray(existing) ? existing : []
        responseHeaders["set-cookie"] = [...existingList, options.setCookie]
      }
      /* v8 ignore next -- plugin responses always carry a status code. */
      options.response.writeHead(pluginResponse.statusCode ?? 502, responseHeaders)
      pluginResponse.pipe(options.response)
      pluginResponse.on("end", () => resolve("ok"))
      /* v8 ignore next -- upstream stream errors after headers truncate the response. */
      pluginResponse.on("error", () =>
        failWith("unreachable", 502, "Plugin response stream failed")
      )
    })
    options.request.pipe(upstream)
    /* v8 ignore next -- client aborts mid-body tear down the upstream request. */
    options.request.on("error", () => upstream.destroy())
  })

export interface SpliceUpgradeOptions {
  readonly port: number
  readonly targetPath: string
  readonly request: IncomingMessage
  readonly socket: Socket
  readonly head: Buffer
  readonly contextHeaders: Readonly<Record<string, string>>
  /// Invoked exactly once when the splice ends — either side closing, or the
  /// upstream connect failing. Lets the caller release the WS keep-alive pin.
  readonly onClose?: () => void
}

/// WebSocket upgrades are spliced at the socket level: the original request
/// head is re-written against the plugin origin and both directions are piped
/// raw. This preserves subprotocols and avoids double-framing through a ws
/// server instance.
export const spliceUpgrade = (options: SpliceUpgradeOptions): void => {
  const upstream = connect({ host: "127.0.0.1", port: options.port })
  let closed = false
  const notifyClose = (): void => {
    if (closed) {
      return
    }
    closed = true
    options.onClose?.()
  }
  const destroyBoth = (): void => {
    upstream.destroy()
    options.socket.destroy()
  }
  upstream.on("error", destroyBoth)
  options.socket.on("error", destroyBoth)
  upstream.on("close", notifyClose)
  options.socket.on("close", notifyClose)
  upstream.on("connect", () => {
    const lines = [`${options.request.method} ${options.targetPath} HTTP/1.1`]
    const raw = options.request.rawHeaders
    for (let index = 0; index < raw.length; index += 2) {
      // rawHeaders always come in name/value pairs.
      const name = raw[index] as string
      const value = raw[index + 1] as string
      const lower = name.toLowerCase()
      if (lower === "host" || lower === "authorization" || lower === "cookie") {
        continue
      }
      lines.push(`${name}: ${value}`)
    }
    lines.push(`Host: 127.0.0.1:${options.port}`)
    for (const [name, value] of Object.entries(options.contextHeaders)) {
      lines.push(`${name}: ${value}`)
    }
    upstream.write(lines.join("\r\n") + "\r\n\r\n")
    if (options.head.length > 0) {
      upstream.write(options.head)
    }
    options.socket.pipe(upstream)
    upstream.pipe(options.socket)
  })
}
