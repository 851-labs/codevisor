import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js"

import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import { accountMeta } from "./mcp-plugin-accounts.js"
import { toolVisibleTo } from "./mcp-plugin-apps.js"
import { makePluginConnection, readPluginResource } from "./mcp-plugin-connection.js"
import type { ConnectUpstream } from "./mcp-upstream.js"

export type McpPluginOperations = Pick<
  McpManager,
  "appView" | "callAppTool" | "pluginConnection" | "readResource" | "subscribeConnections"
>

export const makeMcpPluginOperations = (
  core: McpManagerCore,
  connectUpstream: ConnectUpstream
): McpPluginOperations => {
  const { appViews, config, connectionListeners, record } = core

  return {
    pluginConnection: async (id) => {
      const connection = await connectUpstream(id)
      return makePluginConnection(await record(id), connection, config.accounts)
    },
    readResource: async (id, uri, accountId) =>
      readPluginResource(await connectUpstream(id), config.accounts, id, uri, accountId),
    subscribeConnections: (listener) => {
      connectionListeners.add(listener)
      return () => connectionListeners.delete(listener)
    },
    appView: (viewId) => appViews.get(viewId),
    callAppTool: async (serverId, toolName, args, accountId) => {
      const connection = await connectUpstream(serverId)
      const tool = connection.tools.find((candidate) => candidate.name === toolName)
      if (tool === undefined || !toolVisibleTo(tool, "app")) {
        throw new Error(`${toolName} isn't available to this app`)
      }
      const meta = await accountMeta(config.accounts, serverId, accountId)
      const result = await connection.client.callTool({
        name: toolName,
        arguments: args,
        ...(meta === undefined ? {} : { _meta: meta })
      })
      return CallToolResultSchema.parse(result)
    }
  }
}
