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
}

export const searchToolDescription = (inventory: string): string =>
  [
    "Compatibility discovery endpoint for integrations connected through Codevisor. Prefer run_code for normal work so discovery, schema inspection, and actions can be composed in one invocation. Use this direct wrapper only when the harness cannot run code.",
    inventory
  ].join("\n\n")

export const runCodeToolDescription = (inventory: string): string =>
  [
    "Primary Codevisor tool interface. Run sandboxed JavaScript or TypeScript that discovers and composes enabled integration, Browser Use, and Computer Use tools. Prefer this over direct search/describe/execute calls. The isolate has no filesystem, network, process environment, or credentials.",
    'Inside code, start with `await tools.search({ query: "<intent>" })`, inspect a match with `await tools.describe.tool({ path })`, then call the exact returned path with `await tools[path](args)`. Pass an async arrow function.',
    inventory
  ].join("\n\n")

/// The discovery half of the gateway, split out of mcp-gateway: what tools
/// exist (MCP servers, automation providers, plugin tools), how they are
/// advertised (the inventory string), and how paths resolve to definitions.
export const makeGatewayCatalog = (deps: GatewayCatalogDeps) => {
  const { automationProviders, codevisorProvider, config, connectUpstream } = deps

  const listPluginTools = (): Promise<ReadonlyArray<Tool>> =>
    pluginToolDefinitions(config.pluginTools)

  const integrationInventory = async (projectId?: string, sessionId?: string): Promise<string> => {
    const names = [
      "Codevisor",
      ...(await run(config.db.resolveMcpServers(projectId, sessionId)))
        .filter((server) => server.enabled)
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
      (server) => server.enabled
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
      (candidate) => candidate.id === serverId && candidate.enabled
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
        "Choose a match, call describe with its server and name, then call execute. Do not stop after discovery when the user asked for an action or answer."
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
