import type { IncomingMessage } from "node:http"
import { buffer } from "node:stream/consumers"

import type { CreateMcpServerRequest } from "@codevisor/api"
import type { Client } from "@modelcontextprotocol/sdk/client/index.js"
import type { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import type { Implementation, Tool } from "@modelcontextprotocol/sdk/types.js"
import { Effect } from "effect"

export interface UpstreamConnection {
  readonly client: Client
  readonly close: () => Promise<void>
  tools: ReadonlyArray<Tool>
  readonly serverInfo?: Implementation
}

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const readJsonBody = async (request: IncomingMessage): Promise<unknown> => {
  const body = await buffer(request)
  return JSON.parse(body.toString("utf8")) as unknown
}

export const sdkTransport = (
  transport: StreamableHTTPClientTransport | StreamableHTTPServerTransport
): Transport => {
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion
  return transport as Transport
}

export const errorMessage = (cause: unknown): string => {
  /* v8 ignore next */
  if (cause instanceof Error) return cause.message
  /* v8 ignore next */
  return String(cause)
}

export const reportBackgroundFailure = (operation: string, cause: unknown): void => {
  console.error(`${operation}: ${errorMessage(cause)}`)
}

export const requireHttpUrl = (value: string | undefined): string => {
  if (value === undefined) throw new Error("An HTTP MCP server requires a URL")
  const url = new URL(value)
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error("MCP server URLs must use HTTP or HTTPS")
  }
  return url.toString()
}

export const validateRequest = (
  request: Pick<
    CreateMcpServerRequest,
    | "transport"
    | "url"
    | "command"
    | "env"
    | "headers"
    | "authType"
    | "bearerToken"
    | "oauthScope"
    | "oauthClientId"
    | "oauthClientSecret"
  >
): void => {
  if (request.transport === "http") requireHttpUrl(request.url)
  if (request.transport === "http" && request.env !== undefined) {
    throw new Error("Environment variables are only supported for stdio MCP servers")
  }
  if (request.transport === "stdio" && request.headers !== undefined) {
    throw new Error("HTTP headers are only supported for HTTP MCP servers")
  }
  if (
    request.transport === "stdio" &&
    request.authType !== undefined &&
    request.authType !== "none"
  ) {
    throw new Error("Authorization is only supported for HTTP MCP servers")
  }
  if (
    request.transport === "stdio" &&
    (request.bearerToken !== undefined ||
      request.oauthScope !== undefined ||
      request.oauthClientId !== undefined ||
      request.oauthClientSecret !== undefined)
  ) {
    throw new Error("Authorization credentials are only supported for HTTP MCP servers")
  }
  if (request.transport === "stdio" && request.command?.trim().length === 0) {
    throw new Error("A stdio MCP server requires a command")
  }
  if (request.transport === "stdio" && request.command === undefined) {
    throw new Error("A stdio MCP server requires a command")
  }
}

export const suggestedMcpName = (url: URL): string => {
  const labels = url.hostname.split(".").filter(Boolean)
  const candidate = labels.find((label) => !["www", "mcp", "api"].includes(label)) ?? labels[0]
  /* v8 ignore next */
  if (candidate === undefined) return "MCP Server"
  return candidate
    .split(/[-_]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}
