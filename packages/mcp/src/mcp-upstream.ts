import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

import {
  NodeStreamableHttpTransport,
  type StreamableHttpAuthorization
} from "./mcp-http-transport.js"
import type { McpManagerCore } from "./mcp-manager-core.js"
import { connectionSecretsSignature } from "./mcp-secret-update.js"
import { errorMessage, requireHttpUrl, type UpstreamConnection } from "./mcp-support.js"

export interface ConnectUpstreamOptions {
  readonly allowDisabled?: boolean
  readonly preserveState?: boolean
}

export type ConnectUpstream = (
  id: string,
  options?: ConnectUpstreamOptions
) => Promise<UpstreamConnection>

const definedEnvironment = (
  env: Readonly<Record<string, string | undefined>>
): Record<string, string> => {
  const defined: Record<string, string> = {}
  for (const [key, value] of Object.entries(env)) {
    if (value !== undefined) defined[key] = value
  }
  return defined
}

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

export const makeConnectUpstream = (
  core: McpManagerCore,
  oauthAuthorization: (id: string) => StreamableHttpAuthorization
): ConnectUpstream => {
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
      const signedIn =
        bearer !== undefined ||
        (stored.oauth?.credential ?? undefined) !== undefined ||
        stored.oauth?.tokens !== undefined
      if (server.authType === "oauth" && !signedIn) {
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
              env: definedEnvironment({ ...process.env, ...stored.env }),
              stderr: "pipe"
            })
          : new NodeStreamableHttpTransport(
              new URL(requireHttpUrl(server.url)),
              bearer === undefined && server.authType === "oauth" ? oauthAuthorization(id) : bearer,
              stored.headers
            )
      let phase = "initialize"
      try {
        await client.connect(transport)
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
            connectionSecretsSignature(secrets(latest)),
            latest.oauthScope,
            JSON.stringify(latest.args)
          ].join("\0") !==
            [
              server.transport,
              server.url,
              server.command,
              server.authType,
              connectionSecretsSignature(stored),
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
        if (
          updated.authType === "oauth" &&
          (updated.connectionState === "expired" ||
            updated.connectionState === "needsAuthorization")
        ) {
          throw cause
        }
        await saveRecord(updated, { connectionState: "error", detail: errorMessage(cause) })
        throw cause
      }
    })()
    connectionLocks.set(id, connecting)
    return connecting.finally(() => {
      if (connectionLocks.get(id) === connecting) connectionLocks.delete(id)
    })
  }
}
