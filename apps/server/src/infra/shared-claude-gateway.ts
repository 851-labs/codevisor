import { createHash } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"

import type { SharedTokenBundle } from "@codevisor/harness-manager"

const digest = (token: string) => createHash("sha256").update(token).digest("hex")
const MAX_BODY = 32 * 1024 * 1024

/// Claude keeps its subscription OAuth mode. Only its API base URL changes;
/// this loopback gateway substitutes the current access token at request time.
/// Provider refresh tokens never enter the Claude process or its profile.
export const makeSharedClaudeGateway = (options: {
  readonly token: (id: string, rejected?: string) => Promise<SharedTokenBundle>
  readonly fetch?: typeof fetch
}) => {
  const credentials = new Map<string, string>()
  const requestUpstream = options.fetch ?? fetch
  return {
    register: (id: string, accessToken: string) => {
      credentials.set(digest(accessToken), id)
    },
    forget: (id: string) => {
      for (const [key, value] of credentials) if (value === id) credentials.delete(key)
    },
    close: () => credentials.clear(),
    handle: async (request: IncomingMessage, response: ServerResponse, url: URL): Promise<void> => {
      response.setHeader("Cache-Control", "no-store")
      // Do not expose the gateway through the native client's sealed relay or
      // to websites using the machine API's trusted-loopback exception.
      const address = request.socket.remoteAddress
      if (
        request.headers.origin !== undefined ||
        !["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(address ?? "")
      ) {
        response.writeHead(403).end()
        return
      }
      const bearer = request.headers.authorization?.match(/^Bearer (.+)$/i)?.[1]
      const id = bearer === undefined ? undefined : credentials.get(digest(bearer))
      if (id === undefined) {
        response.writeHead(401).end()
        return
      }
      const path = url.pathname.slice("/harness/claude".length)
      if (
        !(
          (request.method === "POST" &&
            ["/v1/messages", "/v1/messages/count_tokens"].includes(path)) ||
          (request.method === "GET" && path === "/v1/models")
        )
      ) {
        response.writeHead(404).end()
        return
      }
      const abort = new AbortController()
      const disconnected = () => {
        if (!response.writableFinished) abort.abort()
      }
      response.once("close", disconnected)
      try {
        const chunks: Buffer[] = []
        let size = 0
        for await (const chunk of request) {
          const bytes = Buffer.from(chunk)
          size += bytes.length
          if (size > MAX_BODY) {
            response.writeHead(413).end()
            return
          }
          chunks.push(bytes)
        }
        const body = request.method === "POST" ? Buffer.concat(chunks) : undefined
        const headers = new Headers()
        for (const [name, value] of Object.entries(request.headers)) {
          if (
            typeof value === "string" &&
            (name.startsWith("anthropic-") ||
              ["content-type", "accept", "user-agent", "x-app"].includes(name))
          )
            headers.set(name, value)
        }
        const send = async (rejected?: string) => {
          const token = await options.token(id, rejected)
          headers.set("authorization", `Bearer ${token.accessToken}`)
          const result = await requestUpstream(`https://api.anthropic.com${path}${url.search}`, {
            method: request.method!,
            headers,
            ...(body === undefined ? {} : { body }),
            signal: abort.signal,
            redirect: "error"
          })
          return { result, token: token.accessToken }
        }
        let upstream = await send()
        if (upstream.result.status === 401) {
          await upstream.result.body?.cancel()
          upstream = await send(upstream.token)
        }
        for (const [name, value] of upstream.result.headers) {
          if (
            ![
              "connection",
              "transfer-encoding",
              "content-length",
              "content-encoding",
              "set-cookie",
              "cache-control"
            ].includes(name)
          )
            response.setHeader(name, value)
        }
        response.writeHead(upstream.result.status)
        if (upstream.result.body)
          await pipeline(Readable.fromWeb(upstream.result.body as never), response, {
            signal: abort.signal
          })
        else response.end()
      } catch {
        if (!response.headersSent)
          response.writeHead(503, { "content-type": "application/json" }).end(
            JSON.stringify({
              type: "error",
              error: {
                type: "authentication_error",
                message: "Reconnect this account in Codevisor."
              }
            })
          )
        else response.destroy()
      } finally {
        response.off("close", disconnected)
      }
    }
  }
}
