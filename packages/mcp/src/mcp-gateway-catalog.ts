import type { AutomationToolProvider } from "@codevisor/automation"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import type { McpManagerConfig } from "./mcp-manager.js"
import { PLUGIN_CATALOG_SERVER, pluginToolDefinitions } from "./mcp-plugin-tools.js"
import { run, type UpstreamConnection } from "./mcp-support.js"

export interface CatalogServer {
  readonly id: string
  readonly name: string
}

export interface GatewayCatalogDeps {
  readonly automationProviders: Map<string, AutomationToolProvider>
  readonly codevisorProvider: AutomationToolProvider
  readonly config: McpManagerConfig
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
  /// Machine-local suppression (the per-machine disable overlay). The
  /// catalog consults it everywhere it consults `enabled`: a suppressed
  /// server is not advertised, not listed, and not callable — including
  /// built-in automation providers, which never pass through
  /// `connectUpstream` and would otherwise leak their tools.
  readonly isSuppressed: (name: string) => boolean
}

export const executeToolDescription = (inventory: string): string =>
  [
    "Primary Codevisor tool interface. Run sandboxed JavaScript or TypeScript that discovers and composes enabled integration, Browser Use, and Computer Use tools. The isolate has no filesystem, network, process environment, or credentials.",
    'Inside code, start with `await tools.search({ query: "<intent>" })`, inspect a match with `await tools.describe.tool({ path })`, then call the exact returned path with `await tools[path](args)`. Pass an async arrow function.',
    inventory
  ].join("\n\n")

/// The discovery half of the gateway, split out of mcp-gateway: what tools
/// exist (MCP servers, automation providers, plugin tools), how they are
/// advertised (the inventory string), and how paths resolve to definitions.
export const makeGatewayCatalog = (deps: GatewayCatalogDeps) => {
  const { automationProviders, codevisorProvider, config, connectUpstream, isSuppressed } = deps

  const listPluginTools = (): Promise<ReadonlyArray<Tool>> =>
    pluginToolDefinitions(config.pluginTools)

  const integrationInventory = async (projectId?: string, sessionId?: string): Promise<string> => {
    const names = [
      "Codevisor",
      ...(await run(config.db.resolveMcpServers(projectId, sessionId)))
        .filter((server) => server.enabled && !isSuppressed(server.name))
        .map((server) => server.name.trim())
        .filter((name) => name.length > 0)
    ].sort((left, right) => left.localeCompare(right))
    const pluginTools = await listPluginTools()
    const lines =
      names.length === 0
        ? ["Available integrations: none."]
        : ["Available integrations through Codevisor:", ...names.map((name) => `- ${name}`)]
    if (pluginTools.length > 0) {
      lines.push(
        'Installed plugin tools (call through server "plugin"):',
        ...pluginTools.map((tool) => `- plugin.${tool.name} — ${tool.description}`)
      )
    }
    return lines.join("\n")
  }

  const allTools = async (
    projectId?: string,
    sessionId?: string
  ): Promise<ReadonlyArray<{ server: CatalogServer; tool: Tool }>> => {
    const enabled = (await run(config.db.resolveMcpServers(projectId, sessionId))).filter(
      (server) => server.enabled && !isSuppressed(server.name)
    )
    const results = await Promise.allSettled(
      enabled.map(async (server) => {
        const provider = automationProviders.get(server.id)
        return provider === undefined
          ? { server, tools: (await connectUpstream(server.id)).tools }
          : { server, tools: provider.tools }
      })
    )
    return [
      ...codevisorProvider.tools.map((tool) => ({
        server: { id: "codevisor", name: "Codevisor" },
        tool
      })),
      ...(await listPluginTools()).map((tool) => ({ server: PLUGIN_CATALOG_SERVER, tool })),
      ...results.flatMap((result) =>
        result.status === "fulfilled"
          ? result.value.tools.map((tool) => ({ server: result.value.server, tool }))
          : []
      )
    ]
  }

  const gatewayServerAllowed = async (
    serverId: string,
    projectId?: string,
    sessionId?: string
  ): Promise<boolean> =>
    serverId === "codevisor" ||
    (await run(config.db.resolveMcpServers(projectId, sessionId))).some(
      (candidate) => candidate.id === serverId && candidate.enabled && !isSuppressed(candidate.name)
    )

  const searchCatalog = async (
    projectId: string | undefined,
    sessionId: string,
    query: string,
    limit = 12
  ) => {
    const normalized = query.trim().toLowerCase()
    const terms = normalized.split(/[^a-z0-9]+/).filter((term) => term.length > 1)
    const ranked = (await allTools(projectId, sessionId))
      .map(({ server, tool }) => {
        const serverName = server.name.toLowerCase()
        const toolName = tool.name.toLowerCase()
        const haystack =
          `${server.name} ${tool.name} ${tool.title ?? ""} ${tool.description ?? ""}`.toLowerCase()
        let score = normalized.length > 0 && haystack.includes(normalized) ? 40 : 0
        for (const term of terms) {
          if (serverName.includes(term)) score += 20
          if (toolName.includes(term)) score += 12
          if (haystack.includes(term)) score += 4
        }
        return {
          path: `${server.id}.${tool.name}`,
          server: server.id,
          serverName: server.name,
          name: tool.name,
          title: tool.title,
          description: tool.description,
          score
        }
      })
      .filter((item) => normalized.length === 0 || item.score > 0)
      .sort((left, right) => right.score - left.score || left.path.localeCompare(right.path))
    return {
      items: ranked.slice(0, Math.max(1, Math.min(limit, 50))),
      total: ranked.length,
      workflow:
        "Choose a match, inspect it with tools.describe.tool({ path }), then call tools[path](args). Do not stop after discovery when the user asked for an action or answer."
    }
  }

  const describeCatalogPath = async (
    projectId: string | undefined,
    sessionId: string,
    path: string
  ): Promise<Tool> => {
    const separator = path.indexOf(".")
    if (separator <= 0 || separator === path.length - 1)
      throw new Error(`Invalid tool path: ${path}`)
    const serverId = path.slice(0, separator)
    const toolName = path.slice(separator + 1)
    if (serverId === "plugin") {
      const definition = (await listPluginTools()).find((candidate) => candidate.name === toolName)
      if (definition === undefined) throw new Error(`Tool not found: ${path}`)
      return definition
    }
    const allowed = await gatewayServerAllowed(serverId, projectId, sessionId)
    if (!allowed) throw new Error("Tool server is disabled for this session")
    const provider = automationProviders.get(serverId)
    const definition = (provider?.tools ?? (await connectUpstream(serverId)).tools).find(
      (candidate) => candidate.name === toolName
    )
    if (definition === undefined) throw new Error(`Tool not found: ${path}`)
    return definition
  }

  return {
    allTools,
    describeCatalogPath,
    gatewayServerAllowed,
    integrationInventory,
    listPluginTools,
    searchCatalog
  }
}
