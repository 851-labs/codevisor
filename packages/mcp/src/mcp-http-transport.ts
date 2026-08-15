import { type JSONRPCMessage, JSONRPCMessageSchema } from "@modelcontextprotocol/sdk/types.js"
import type { Transport, TransportSendOptions } from "@modelcontextprotocol/sdk/shared/transport.js"

const messageFromSseBlock = (block: string): unknown | undefined => {
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

export class NodeStreamableHttpTransport implements Transport {
  onclose?: () => void
  onerror?: (error: Error) => void
  onmessage?: <T extends JSONRPCMessage>(message: T) => void
  sessionId?: string

  private controller: AbortController | undefined
  private protocolVersion: string | undefined

  constructor(
    private readonly url: URL,
    private readonly accessToken?: string,
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
    const response = await fetch(this.url, {
      method: "POST",
      headers: this.headers("application/json, text/event-stream"),
      body: JSON.stringify(message),
      signal: this.controller?.signal ?? null
    })
    const sessionId = response.headers.get("mcp-session-id")
    if (sessionId !== null) this.sessionId = sessionId
    if (!response.ok) {
      /* v8 ignore next -- standard Fetch responses expose a readable error body. */
      const detail = await response.text().catch(() => response.statusText)
      throw new Error(`Streamable HTTP error ${response.status}: ${detail}`)
    }
    if (response.status === 202) {
      await response.body?.cancel()
      return
    }
    /* v8 ignore next -- Fetch normalizes a content type for non-empty response bodies. */
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

  private headers(accept: string): Headers {
    const headers = new Headers(this.customHeaders)
    headers.set("accept", accept)
    headers.set("content-type", "application/json")
    if (this.accessToken !== undefined) {
      headers.set("authorization", `Bearer ${this.accessToken}`)
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
      /* v8 ignore next -- split always leaves a final string while the stream is open. */
      pending = chunk.done ? "" : (blocks.pop() ?? "")
      for (const block of blocks) {
        const decoded = messageFromSseBlock(block)
        if (decoded === undefined) {
          console.error(`Unable to decode MCP SSE event (${block.length} characters)`)
          continue
        }
        this.dispatch(decoded)
        /* v8 ignore next -- batched SSE responses are optional and JSON batches are covered above. */
        const messages = Array.isArray(decoded) ? decoded : [decoded]
        if (
          stopAfterId !== undefined &&
          messages.some(
            (message) =>
              typeof message === "object" &&
              message !== null &&
              "id" in message &&
              (message as { id?: unknown }).id === stopAfterId
          )
        ) {
          /* v8 ignore next -- cancellation is best-effort after the matching response arrived. */
          await reader.cancel().catch(() => undefined)
          return
        }
      }
      if (chunk.done) return
    }
  }
}
