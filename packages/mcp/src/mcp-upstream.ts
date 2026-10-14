import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

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

export const makeConnectUpstream = (core: McpManagerCore): ConnectUpstream => {
  const { connectionLocks, connections, record, saveRecord, secrets, state } = core

  return async (id, options = {}) => {
    const cached = connections.get(id)
    if (cached !== undefined) return cached
    const pending = connectionLocks.get(id)
    /* v8 ignore next */
    if (pending !== undefined) return pending

    const connecting = (async () => {
      let abandoned = false
      const owns = (): boolean => connectionLocks.get(id) === connecting
      const checkOwner = (): void => {
        if (!owns()) {
          abandoned = true
          throw new Error(`MCP connection ${id} was superseded`)
        }
      }
      const server = await record(id)
      checkOwner()
      if (server.kind !== "managed") throw new Error(`${server.name} is an internal provider`)
      if (!server.enabled && options.allowDisabled !== true) {
        throw new Error(`${server.name} is disabled`)
      }
      if (state.locallySuppressed.has(server.name)) {
        throw new Error(`${server.name} is disabled on this machine`)
      }
      const stored = secrets(server)
      const bearer =
        stored.bearerToken === undefined || stored.bearerToken === ""
          ? undefined
          : stored.bearerToken
      const accessToken = bearer ?? stored.oauth?.tokens?.access_token
      if (server.authType === "oauth" && accessToken === undefined) {
        if (server.connectionState !== "needsAuthorization") {
          await saveRecord(server, {
            connectionState: "needsAuthorization",
            toolCount: 0,
            detail: undefined
          })
        }
        throw new Error(`${server.name} needs authorization`)
      }
      /* v8 ignore next */
      if (options.preserveState !== true) {
        await saveRecord(server, { connectionState: "connecting", detail: undefined })
      }
      checkOwner()
      const client = new Client({ name: "Codevisor", version: "0.1.0" }, { capabilities: {} })
      const transport =
        server.transport === "stdio"
          ? new StdioClientTransport({
              /* v8 ignore next */
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
      try {
        await client.connect(transport as unknown as Transport)
        phase = "tools/list"
        const tools = await listAllUpstreamTools(client)
        const latest = await record(id)
        checkOwner()
        if (
          (!latest.enabled && options.allowDisabled !== true) ||
          state.locallySuppressed.has(latest.name) ||
          [
            latest.transport,
            latest.url,
            latest.command,
            latest.authType,
            latest.secretCipher,
            latest.oauthScope,
            JSON.stringify(latest.args)
          ].join("\0") !==
            [
              server.transport,
              server.url,
              server.command,
              server.authType,
              server.secretCipher,
              server.oauthScope,
              JSON.stringify(server.args)
            ].join("\0")
        ) {
          abandoned = true
          throw new Error(`${latest.name} changed while connecting`)
        }
        const serverInfo = client.getServerVersion()
        const connection: UpstreamConnection = {
          client,
          close: () => client.close(),
          tools,
          ...(serverInfo === undefined ? {} : { serverInfo })
        }
        connections.set(id, connection)
        const updated = await record(id)
        checkOwner()
        await saveRecord(updated, {
          connectionState: "connected",
          toolCount: tools.length,
          detail: undefined
        })
        return connection
      } catch (cause) {
        /* v8 ignore next */
        await client.close().catch(() => undefined)
        if (abandoned || !owns()) throw cause
        console.error(
          `MCP connection failed for ${server.name} during ${phase}: ${errorMessage(cause)}`
        )
        const updated = await record(id)
        checkOwner()
        /* v8 ignore next */
        const needsAuthorization = server.authType === "oauth" && accessToken === undefined
        await saveRecord(updated, {
          /* v8 ignore next */
          connectionState: needsAuthorization ? "needsAuthorization" : "error",
          detail: errorMessage(cause)
        })
        throw cause
      }
    })()
    connectionLocks.set(id, connecting)
    return connecting.finally(() => {
      if (connectionLocks.get(id) === connecting) connectionLocks.delete(id)
    })
  }
}
