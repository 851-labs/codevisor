import type { CreateMcpServerRequest } from "@codevisor/api"
import type { Client } from "@modelcontextprotocol/sdk/client/index.js"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import type { IncomingMessage } from "node:http"
import { Effect } from "effect"

export interface UpstreamConnection {
  readonly client: Client
  readonly close: () => Promise<void>
  tools: ReadonlyArray<Tool>
}

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

/// Buffer and parse a JSON request body. The parsed value is handed to the
/// SDK transport (which accepts pre-parsed bodies), so consuming the stream
/// here is safe.
export const readJsonBody = async (request: IncomingMessage): Promise<unknown> => {
  const chunks: Array<Buffer> = []
  // Without setEncoding, node HTTP request streams always yield Buffers.
  for await (const chunk of request) {
    chunks.push(chunk as Buffer)
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown
}

export const errorMessage = (cause: unknown): string => {
  /* v8 ignore next -- SDK, database, HTTP, and runtime failures use Error instances. */
  if (cause instanceof Error) return cause.message
  /* v8 ignore next -- retained for defensive formatting of external throwables. */
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
  /* v8 ignore next -- a valid HTTP(S) URL always has at least one hostname label. */
  if (candidate === undefined) return "MCP Server"
  return candidate
    .split(/[-_]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}
