import type { Readable, Writable } from "node:stream"

import type { CallToolRequest, CallToolResult } from "@modelcontextprotocol/server"
import { CLIENT_INFO_META_KEY, Server } from "@modelcontextprotocol/server"
import { serveStdio, StdioServerTransport } from "@modelcontextprotocol/server/stdio"

import { EXECUTE_MAX_TIMEOUT_MS } from "./mcp-gateway-execution.js"
import { isRecord } from "./mcp-guards.js"
import { makeGatewayLink, type GatewayLink, type IssuedGateway } from "./mcp-stdio-gateway-link.js"
import { errorMessage } from "./mcp-support.js"

export type { IssuedGateway } from "./mcp-stdio-gateway-link.js"

export interface GatewayBridgeOptions {
  readonly version: string
  readonly issueGateway: (clientName: string | undefined) => Promise<IssuedGateway>
  readonly input: Readable
  readonly output: Writable
}

export interface GatewayBridge {
  readonly close: () => Promise<void>
}

const callMarginMs = 60_000
const callTimeoutMs = EXECUTE_MAX_TIMEOUT_MS + callMarginMs

export const serveGatewayOverStdio = (options: GatewayBridgeOptions): GatewayBridge => {
  const links = new Set<GatewayLink>()
  const handle = serveStdio(() => bridgeServer(options, links), {
    transport: new StdioServerTransport(options.input, options.output)
  })
  return {
    close: async () => {
      await handle.close()
      await Promise.all([...links].map((link) => link.close()))
    }
  }
}

const bridgeServer = (options: GatewayBridgeOptions, links: Set<GatewayLink>): Server => {
  const server = new Server(
    { name: "codevisor", version: options.version },
    { capabilities: { tools: { listChanged: true } } }
  )
  const caller: { name?: string | undefined } = {}
  const link = makeGatewayLink({
    version: options.version,
    issue: () => options.issueGateway(server.getClientVersion()?.name ?? caller.name),
    onToolsChanged: () => announceToolsChanged(server)
  })
  links.add(link)

  server.setRequestHandler("tools/list", (request, ctx) => {
    caller.name ??= envelopeClientName(ctx.mcpReq.envelope)
    return link.use((client) => client.listTools(request.params))
  })
  server.setRequestHandler("tools/call", (request, ctx) => {
    caller.name ??= envelopeClientName(ctx.mcpReq.envelope)
    return forwardCall(server, link, request.params, ctx.mcpReq.signal)
  })
  // oxlint-disable-next-line unicorn/prefer-add-event-listener
  server.onclose = () => void link.close()
  return server
}

const forwardCall = async (
  server: Server,
  link: GatewayLink,
  params: CallToolRequest["params"],
  signal: AbortSignal
): Promise<CallToolResult> => {
  try {
    const result = await link.use((client) =>
      client.callTool(params, { signal, timeout: callTimeoutMs })
    )
    return server.projectCallToolResult(result, undefined)
  } catch (cause) {
    return { isError: true, content: [{ type: "text", text: errorMessage(cause) }] }
  }
}

const envelopeClientName = (envelope: unknown): string | undefined => {
  if (!isRecord(envelope)) return undefined
  const info = envelope[CLIENT_INFO_META_KEY]
  if (!isRecord(info) || typeof info["name"] !== "string") return undefined
  return info["name"]
}

const announceToolsChanged = (server: Server): void => {
  void server.sendToolListChanged().catch(() => undefined)
}
