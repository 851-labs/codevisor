import type { Transport, TransportSendOptions } from "@modelcontextprotocol/sdk/shared/transport.js"
import { type JSONRPCMessage, JSONRPCMessageSchema } from "@modelcontextprotocol/sdk/types.js"

import { isRecord } from "./mcp-guards.js"

const messageFromSseBlock = (block: string): unknown => {
  const data = block
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart())
    .join("\n")
  if (data.length === 0) return undefined
  try {
    return JSON.parse(data) as unknown
  } catch {
    return undefined
  }
}

export interface StreamableHttpAuthorization {
  readonly accessToken: () => Promise<string | undefined>
  readonly recoverUnauthorized: (
    rejectedAccessToken: string | undefined
  ) => Promise<{ readonly retry: true } | { readonly retry: false; readonly reason: string }>
}

export class NodeStreamableHttpTransport implements Transport {
  onclose?: () => void
  onerror?: (error: Error) => void
  onmessage?: (message: JSONRPCMessage) => void
  sessionId?: string

  private controller: AbortController | undefined
  private protocolVersion: string | undefined

  constructor(
    private readonly url: URL,
    private readonly authorization?: string | StreamableHttpAuthorization,
    private readonly customHeaders: Readonly<Record<string, string>> = {}
  ) {}

  setProtocolVersion(version: string): void {
    this.protocolVersion = version
  }

  async start(): Promise<void> {
    if (this.controller !== undefined) throw new Error("MCP HTTP transport is already started")
    this.controller = new AbortController()
  }

  async send(message: JSONRPCMessage, _options?: TransportSendOptions): Promise<void> {
    const response = await this.post(message)
    const sessionId = response.headers.get("mcp-session-id")
    if (sessionId !== null) this.sessionId = sessionId
    if (!response.ok) {
      /* v8 ignore next */
      const detail = await response.text().catch(() => response.statusText)
      throw new Error(`Streamable HTTP error ${response.status}: ${detail}`)
    }
    if (response.status === 202) {
      await response.body?.cancel()
      return
    }
    /* v8 ignore next */
    const contentType = response.headers.get("content-type") ?? ""
    if (contentType.includes("application/json")) {
      this.dispatch(await response.json())
      return
    }
    if (contentType.includes("text/event-stream")) {
      const requestId = "id" in message ? message.id : undefined
      await this.consumeSse(response, requestId)
      return
    }
    await response.body?.cancel()
    throw new Error(`Unexpected MCP response content type: ${contentType}`)
  }

  async close(): Promise<void> {
    this.controller?.abort()
    this.controller = undefined
    this.onclose?.()
  }

  private async post(message: JSONRPCMessage): Promise<Response> {
    const authorization = this.authorization
    const attempt = async (accessToken: string | undefined): Promise<Response> =>
      fetch(this.url, {
        method: "POST",
        headers: this.headers("application/json, text/event-stream", accessToken),
        body: JSON.stringify(message),
        signal: this.controller?.signal ?? null
      })
    if (typeof authorization !== "object") return attempt(authorization)
    const accessToken = await authorization.accessToken()
    const response = await attempt(accessToken)
    if (response.status !== 401) return response
    await response.body?.cancel()
    const recovery = await authorization.recoverUnauthorized(accessToken)
    if (!recovery.retry) throw new Error(`Streamable HTTP error 401: ${recovery.reason}`)
    return attempt(await authorization.accessToken())
  }

  private headers(accept: string, accessToken: string | undefined): Headers {
    const headers = new Headers(this.customHeaders)
    headers.set("accept", accept)
    headers.set("content-type", "application/json")
    if (accessToken !== undefined) {
      headers.set("authorization", `Bearer ${accessToken}`)
    }
    if (this.sessionId !== undefined) headers.set("mcp-session-id", this.sessionId)
    if (this.protocolVersion !== undefined) {
      headers.set("mcp-protocol-version", this.protocolVersion)
    }
    return headers
  }

  private dispatch(decoded: unknown): void {
    const messages = Array.isArray(decoded) ? decoded : [decoded]
    for (const message of messages) {
      this.onmessage?.(JSONRPCMessageSchema.parse(message))
    }
  }

  private async consumeSse(response: Response, stopAfterId?: string | number): Promise<void> {
    if (response.body === null) return
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let pending = ""
    while (true) {
      const chunk = await reader.read()
      pending += decoder.decode(chunk.value, { stream: !chunk.done })
      const blocks = pending.split(/\r?\n\r?\n/)
      /* v8 ignore next */
      if (chunk.done) pending = ""
      else pending = blocks.pop() ?? ""
      for (const block of blocks) {
        const decoded = messageFromSseBlock(block)
        if (decoded === undefined) {
          console.error(`Unable to decode MCP SSE event (${block.length} characters)`)
          continue
        }
        this.dispatch(decoded)
        /* v8 ignore next */
        const messages = Array.isArray(decoded) ? decoded : [decoded]
        if (
          stopAfterId !== undefined &&
          messages.some((message) => isRecord(message) && message.id === stopAfterId)
        ) {
          /* v8 ignore next */
          await reader.cancel().catch(() => undefined)
          return
        }
      }
      if (chunk.done) return
    }
  }
}
