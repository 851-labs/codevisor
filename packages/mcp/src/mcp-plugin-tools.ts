import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import type { CatalogServer } from "./mcp-gateway-catalog.js"

/// One plugin-declared agent tool, flattened by the plugins manager.
/// Structural mirror of @codevisor/plugins' PluginToolSummary so this package
/// needs no dependency on the plugins package.
export interface PluginGatewayTool {
  readonly pluginId: string
  readonly name: string
  readonly description: string
  /// The manifest's opaque JSON Schema for the tool's arguments; absent means
  /// "any JSON object".
  readonly inputSchema?: unknown
}

/// Structural seam over the plugins manager: list and invoke plugin tools and
/// observe installed-set changes. @codevisor/plugins' PluginsManager
/// satisfies this as-is, so the server wires it straight into
/// McpManagerConfig.pluginTools without a package dependency.
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

/// Plugin tools ride the catalog as server "plugin" with dotted tool names
/// (`<pluginId>.<toolName>`), so the agent-visible paths read
/// `plugin.<pluginId>.<toolName>`.
export const PLUGIN_CATALOG_SERVER: CatalogServer = { id: "plugin", name: "Plugins" }

/// Plugin tool definitions in catalog shape (dotted names). Recomputed on
/// every listing so a fresh install/uninstall is immediately reflected in
/// search/describe/execute; the advertised inventory string refreshes through
/// the plugins manager subscription in mcp-manager.
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

/// Invokes one plugin tool from a `plugin.<pluginId>.<toolName>` catalog path
/// (the `<pluginId>.<toolName>` remainder arrives here). Plugin ids contain
/// the namespace dot (`owner.name`) while tool names cannot, so the LAST dot
/// splits them. `context` carries the calling session's cwd when known.
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
