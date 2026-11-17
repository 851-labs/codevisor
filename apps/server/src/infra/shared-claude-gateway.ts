import { createHash } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"
import { pipeline } from "node:stream/promises"

import { SharedCredentialError, type SharedTokenBundle } from "@codevisor/harness-manager"

import { BoundedBody, isLocalhost } from "../server-http.js"

export const claudeGatewayRoute = "/harness/claude"

export const chatGatewayUrl = (gatewayUrl: string, chatId: string): string =>
  `${gatewayUrl}${chatSegment}${chatId}`

const maxBodyBytes = 32 * 1024 * 1024
const chatSegment = "/chats/"
const chatPath = /^\/chats\/(?<chatId>[^/]+)(?<rest>\/.*)$/
const upstreamOrigin = "https://api.anthropic.com"
const postPaths = new Set(["/v1/messages", "/v1/messages/count_tokens"])
const forwardedHeaderNames = new Set(["content-type", "accept", "user-agent", "x-app"])
const strippedResponseHeaders = new Set([
  "connection",
  "transfer-encoding",
  "content-length",
  "content-encoding",
  "set-cookie",
  "cache-control"
])
const reconnectError = {
  type: "error",
  error: {
    type: "authentication_error",
    message: "Reconnect this account in Codevisor."
  }
}

interface UpstreamCall {
  readonly id: string
  readonly request: IncomingMessage
  readonly url: URL
  readonly path: string
  readonly headers: Headers
  readonly body: Buffer<ArrayBuffer> | undefined
  readonly abort: AbortController
}

interface UpstreamReply {
  readonly result: Response
  readonly token: string
}

interface GatewayRoute {
  readonly chatId?: string
  readonly path: string
}

export const makeSharedClaudeGateway = (options: {
  readonly token: (id: string, rejected?: string) => Promise<SharedTokenBundle>
  readonly chatAccount?: (chatId: string) => Promise<string | undefined>
  readonly fetch?: typeof fetch
}) => {
  const credentials = new Map<string, string>()
  const requestUpstream = options.fetch ?? fetch
  const send = async (call: UpstreamCall, rejected?: string): Promise<UpstreamReply> => {
    const token = await options.token(call.id, rejected)
    call.headers.set("authorization", `Bearer ${token.accessToken}`)
    const result = await requestUpstream(`${upstreamOrigin}${call.path}${call.url.search}`, {
      method: call.request.method!,
      headers: call.headers,
      ...(call.body === undefined ? {} : { body: call.body }),
      signal: call.abort.signal,
      redirect: "error"
    })
    return { result, token: token.accessToken }
  }
  const servingAccount = async (route: GatewayRoute, caller: string): Promise<string> => {
    if (route.chatId === undefined) return caller
    return (await options.chatAccount?.(route.chatId)) ?? caller
  }
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
      if (isForeignCaller(request)) return reply(response, 403)

      const caller = accountFor(credentials, request)
      if (caller === undefined) return reply(response, 401)

      const route = gatewayRoute(url.pathname)
      if (!isProxiedRoute(request, route.path)) return reply(response, 404)

      const abort = new AbortController()
      const disconnected = abortUnlessFinished(response, abort)
      response.once("close", disconnected)
      try {
        const received = new BoundedBody(maxBodyBytes)
        for await (const chunk of request) if (!received.accept(chunk)) return reply(response, 413)

        const body = request.method === "POST" ? received.bytes() : undefined
        const id = await servingAccount(route, caller)
        const path = route.path
        const call = { id, request, url, path, headers: forwardedHeaders(request), body, abort }
        let upstream = await send(call)
        if (upstream.result.status === 401) {
          await upstream.result.body?.cancel()
          upstream = await send(call, upstream.token)
        }

        copyResponseHeaders(upstream.result.headers, response)
        response.writeHead(upstream.result.status)
        if (upstream.result.body)
          await pipeline(upstream.result.body, response, { signal: abort.signal })
        else response.end()
      } catch (cause) {
        failRequest(response, cause)
      } finally {
        response.off("close", disconnected)
      }
    }
  }
}

const digest = (token: string) => createHash("sha256").update(token).digest("hex")

const gatewayRoute = (pathname: string): GatewayRoute => {
  const path = pathname.slice(claudeGatewayRoute.length)
  const { chatId, rest } = chatPath.exec(path)?.groups ?? {}
  if (chatId === undefined || rest === undefined) return { path }

  return { chatId, path: rest }
}

const reply = (response: ServerResponse, status: number): void => {
  response.writeHead(status).end()
}

const isForeignCaller = (request: IncomingMessage): boolean => {
  const address = request.socket.remoteAddress
  return request.headers.origin !== undefined || !isLocalhost(address)
}

const accountFor = (
  credentials: ReadonlyMap<string, string>,
  request: IncomingMessage
): string | undefined => {
  const bearer = request.headers.authorization?.match(/^Bearer (.+)$/i)?.[1]
  if (bearer === undefined) return undefined
  return credentials.get(digest(bearer))
}

const isProxiedRoute = (request: IncomingMessage, path: string): boolean =>
  (request.method === "POST" && postPaths.has(path)) ||
  (request.method === "GET" && path === "/v1/models")

const abortUnlessFinished = (response: ServerResponse, abort: AbortController) => () => {
  if (!response.writableFinished) abort.abort()
}

const forwardedHeaders = (request: IncomingMessage): Headers => {
  const headers = new Headers()
  for (const [name, value] of Object.entries(request.headers))
    if (typeof value === "string" && isForwardedHeader(name)) headers.set(name, value)
  return headers
}

const isForwardedHeader = (name: string): boolean =>
  name.startsWith("anthropic-") || forwardedHeaderNames.has(name)

const copyResponseHeaders = (headers: Headers, response: ServerResponse): void => {
  for (const [name, value] of headers)
    if (!strippedResponseHeaders.has(name)) response.setHeader(name, value)
}

const failRequest = (response: ServerResponse, cause: unknown): void => {
  const signedOut = isSignedOut(cause)
  if (response.headersSent) {
    response.destroy()
    return
  }
  response
    .writeHead(signedOut ? 401 : 503, { "content-type": "application/json" })
    .end(JSON.stringify(reconnectError))
}

const isSignedOut = (cause: unknown): boolean =>
  cause instanceof SharedCredentialError &&
  (cause.reason === "reauthenticate" || cause.reason === "revoked")
