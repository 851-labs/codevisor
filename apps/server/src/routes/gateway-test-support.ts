import { StreamableHTTPClientTransport } from "@modelcontextprotocol/client"

export const gatewayTransport = (gateway: {
  readonly url: string
  readonly bearerToken: string
}): StreamableHTTPClientTransport =>
  new StreamableHTTPClientTransport(new URL(gateway.url), {
    requestInit: { headers: { Authorization: `Bearer ${gateway.bearerToken}` } }
  })
