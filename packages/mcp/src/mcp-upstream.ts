import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { NodeStreamableHttpTransport } from "./mcp-http-transport.js"
import type { McpManagerCore } from "./mcp-manager-core.js"
import { errorMessage, requireHttpUrl, type UpstreamConnection } from "./mcp-support.js"

export interface ConnectUpstreamOptions {
  readonly allowDisabled?: boolean
  readonly preserveState?: boolean
}

export type ConnectUpstream = (
  id: string,
  options?: ConnectUpstreamOptions
) => Promise<UpstreamConnection>

const listAllUpstreamTools = async (client: Client): Promise<ReadonlyArray<Tool>> => {
  const tools: Tool[] = []
  let cursor: string | undefined
  do {
    const page = await client.listTools(cursor === undefined ? undefined : { cursor })
    tools.push(...page.tools)
    cursor = page.nextCursor
  } while (cursor !== undefined)
  return tools
}

/// Opens (or reuses) the live client connection to one managed upstream MCP
/// server, persisting the resulting connection state on the record.
export const makeConnectUpstream = (core: McpManagerCore): ConnectUpstream => {
  const { connectionLocks, connections, record, saveRecord, secrets, state } = core

  return async (id, options = {}) => {
    const cached = connections.get(id)
    if (cached !== undefined) return cached
    const pending = connectionLocks.get(id)
    /* v8 ignore next -- concurrent connection callers normally observe the completed cache above. */
    if (pending !== undefined) return pending

    const connecting = (async () => {
      const server = await record(id)
      if (server.kind !== "managed") throw new Error(`${server.name} is an internal provider`)
      // Refusals before the try/finally below must release the lock too, or
      // every later caller would be handed this rejected promise.
      if (!server.enabled && options.allowDisabled !== true) {
        connectionLocks.delete(id)
        throw new Error(`${server.name} is disabled`)
      }
      if (state.locallySuppressed.has(server.name)) {
        connectionLocks.delete(id)
        throw new Error(`${server.name} is disabled on this machine`)
      }
      const stored = secrets(server)
      // An empty bearer token is NO token — `""` must never shadow the
      // OAuth access token a sync import delivered (PostHog answers an
      // empty Authorization header with "No token provided" forever).
      const bearer =
        stored.bearerToken === undefined || stored.bearerToken === ""
          ? undefined
          : stored.bearerToken
      const accessToken = bearer ?? stored.oauth?.tokens?.access_token
      // An enabled OAuth server without tokens is a known state, not a
      // connection to attempt: report it and let the user authorize.
      if (server.authType === "oauth" && accessToken === undefined) {
        if (server.connectionState !== "needsAuthorization") {
          await saveRecord(server, {
            connectionState: "needsAuthorization",
            toolCount: 0,
            detail: undefined
          })
        }
        connectionLocks.delete(id)
        throw new Error(`${server.name} needs authorization`)
      }
      /* v8 ignore next -- preserveState is reserved for the live OAuth validation path. */
      if (options.preserveState !== true) {
        await saveRecord(server, { connectionState: "connecting", detail: undefined })
      }
      const client = new Client({ name: "Codevisor", version: "0.1.0" }, { capabilities: {} })
      const transport =
        server.transport === "stdio"
          ? new StdioClientTransport({
              /* v8 ignore next -- stdio records are validated to require a command before saving. */
              command: server.command ?? "",
              args: [...server.args],
              env: { ...process.env, ...stored.env } as Record<string, string>,
              stderr: "pipe"
            })
          : new NodeStreamableHttpTransport(
              new URL(requireHttpUrl(server.url)),
              accessToken,
              stored.headers
            )
      let phase = "initialize"
      let abandoned = false
      try {
        await client.connect(transport as unknown as Transport)
        phase = "tools/list"
        const tools = await listAllUpstreamTools(client)
        // Connections settle in the background, so the server may have
        // been switched off mid-handshake: never cache (or report) a
        // connection the record no longer wants.
        const latest = await record(id)
        if (
          (!latest.enabled && options.allowDisabled !== true) ||
          state.locallySuppressed.has(latest.name)
        ) {
          abandoned = true
          throw new Error(`${latest.name} was disabled while connecting`)
        }
        const connection: UpstreamConnection = {
          client,
          close: () => client.close(),
          tools
        }
        connections.set(id, connection)
        const updated = await record(id)
        await saveRecord(updated, {
          connectionState: "connected",
          toolCount: tools.length,
          detail: undefined
        })
        return connection
      } catch (cause) {
        /* v8 ignore next -- best-effort cleanup after the original connection failure. */
        await client.close().catch(() => undefined)
        // The disable already recorded its own state; leave it be.
        if (abandoned) throw cause
        console.error(
          `MCP connection failed for ${server.name} during ${phase}: ${errorMessage(cause)}`
        )
        const updated = await record(id)
        /* v8 ignore next -- OAuth connection failures are handled by live completion validation. */
        const needsAuthorization = server.authType === "oauth" && accessToken === undefined
        await saveRecord(updated, {
          /* v8 ignore next -- OAuth failures are classified by the live validation path. */
          connectionState: needsAuthorization ? "needsAuthorization" : "error",
          detail: errorMessage(cause)
        })
        throw cause
      } finally {
        connectionLocks.delete(id)
      }
    })()
    connectionLocks.set(id, connecting)
    return connecting
  }
}
