import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport as McpTransport } from "@modelcontextprotocol/sdk/shared/transport.js"

export const gatewayTransport = (gateway: {
  readonly url: string
  readonly bearerToken: string
}): McpTransport => {
  const inner = new StreamableHTTPClientTransport(new URL(gateway.url), {
    requestInit: { headers: { Authorization: `Bearer ${gateway.bearerToken}` } }
  })
  const transport: McpTransport = {
    start: () => inner.start(),
    send: (message, options) => inner.send(message, options),
    close: () => inner.close(),
    setProtocolVersion: (version) => inner.setProtocolVersion(version)
  }
  const forward: Pick<McpTransport, "onclose" | "onerror" | "onmessage"> = {
    onclose: () => transport.onclose?.(),
    onerror: (error) => transport.onerror?.(error),
    onmessage: (message, extra) => transport.onmessage?.(message, extra)
  }
  Object.assign(inner, forward)
  return transport
}
