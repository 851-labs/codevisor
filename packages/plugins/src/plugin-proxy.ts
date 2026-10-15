import type { IncomingMessage, ServerResponse } from "node:http"
import { request as httpRequest } from "node:http"
import { connect } from "node:net"
import type { Duplex } from "node:stream"

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

const HOP_BY_HOP_RESPONSE_HEADERS = new Set(["connection", "keep-alive", "transfer-encoding"])

export interface ForwardHttpOptions {
  readonly port: number
  readonly targetPath: string
  readonly request: IncomingMessage
  readonly response: ServerResponse
  readonly contextHeaders: Readonly<Record<string, string>>
  readonly cookieHeader: string | undefined
  readonly setCookie?: string | undefined
  readonly timeoutMs: number
}

export type ForwardHttpOutcome = "ok" | "timeout" | "unreachable"

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
      /* v8 ignore next 4 */
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
        const existing = responseHeaders["set-cookie"]
        const existingList = Array.isArray(existing) ? existing : []
        responseHeaders["set-cookie"] = [...existingList, options.setCookie]
      }
      /* v8 ignore next */
      options.response.writeHead(pluginResponse.statusCode ?? 502, responseHeaders)
      pluginResponse.pipe(options.response)
      pluginResponse.on("end", () => resolve("ok"))
      /* v8 ignore next */
      pluginResponse.on("error", () =>
        failWith("unreachable", 502, "Plugin response stream failed")
      )
    })
    options.request.pipe(upstream)
    /* v8 ignore next */
    options.request.on("error", () => upstream.destroy())
  })

export interface SpliceUpgradeOptions {
  readonly port: number
  readonly targetPath: string
  readonly request: Pick<IncomingMessage, "method" | "rawHeaders">
  readonly socket: Duplex
  readonly head: Buffer
  readonly contextHeaders: Readonly<Record<string, string>>
  readonly onClose?: () => void
}

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
    let headerName: string | undefined
    for (const entry of options.request.rawHeaders) {
      if (headerName === undefined) {
        headerName = entry
        continue
      }
      const lower = headerName.toLowerCase()
      if (lower !== "host" && lower !== "authorization" && lower !== "cookie") {
        lines.push(`${headerName}: ${entry}`)
      }
      headerName = undefined
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
