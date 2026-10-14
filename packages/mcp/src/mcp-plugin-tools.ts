import type { Tool } from "@modelcontextprotocol/sdk/types.js"

import type { CatalogServer } from "./mcp-gateway-catalog.js"

export interface PluginGatewayTool {
  readonly pluginId: string
  readonly name: string
  readonly description: string
  readonly inputSchema?: unknown
}

export interface PluginToolSource {
  readonly listTools: () => Promise<ReadonlyArray<PluginGatewayTool>>
  readonly invokeTool: (
    pluginId: string,
    toolName: string,
    args: Readonly<Record<string, unknown>>,
    context: { readonly cwd?: string | undefined }
  ) => Promise<unknown>
  readonly subscribeInstalled: (listener: () => void) => () => void
}

export const PLUGIN_CATALOG_SERVER: CatalogServer = { id: "plugin", name: "Plugins" }

export const pluginToolDefinitions = async (
  source: PluginToolSource | undefined
): Promise<ReadonlyArray<Tool>> => {
  if (source === undefined) return []
  return (await source.listTools()).map((tool) => ({
    name: `${tool.pluginId}.${tool.name}`,
    description: tool.description,
    inputSchema: (tool.inputSchema ?? { type: "object" }) as Tool["inputSchema"]
  }))
}

export const invokeGatewayPluginTool = async (
  source: PluginToolSource | undefined,
  name: string,
  args: Readonly<Record<string, unknown>>,
  context: { readonly cwd?: string | undefined }
): Promise<unknown> => {
  if (source === undefined) throw new Error("Plugin tools are unavailable on this server")
  const separator = name.lastIndexOf(".")
  if (separator <= 0 || separator === name.length - 1) {
    throw new Error(`Invalid plugin tool path: plugin.${name}`)
  }
  return source.invokeTool(name.slice(0, separator), name.slice(separator + 1), args, context)
}
