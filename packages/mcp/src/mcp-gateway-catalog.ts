import {
  CODEVISOR_BOT_TOOL_NAMES,
  CODEVISOR_CONVERSATIONAL_BOT_TOOL_NAMES,
  type AutomationToolProvider
} from "@codevisor/automation"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

import { automationSkills } from "./mcp-automation-builtins.js"
import {
  executeSkill,
  packagedSkill,
  skillEntries,
  type BuiltinSkill,
  type SkillEntry
} from "./mcp-gateway-skills.js"
import type { McpManagerConfig } from "./mcp-manager-types.js"
import { PLUGIN_CATALOG_SERVER, pluginToolDefinitions } from "./mcp-plugin-tools.js"
import { run, type UpstreamConnection } from "./mcp-support.js"

export interface CatalogServer {
  readonly id: string
  readonly name: string
}

export interface GatewayCatalogDeps {
  readonly automationProviders: Map<string, AutomationToolProvider>
  readonly config: McpManagerConfig
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
  readonly isSuppressed: (name: string) => boolean
}

const BUILTIN_CAPABILITIES: Record<string, string> = {
  browser:
    "Browser: a real web browser. Open any site, sign in, click, fill in forms, read live pages.",
  computer: "Desktop: see and control the apps on this Mac, and record the screen.",
  codevisor:
    "Codevisor: start other agents, use the user's other machines, control the Codevisor app."
}

const INTEGRATION_LIMIT = 40

export const executeToolDescription = (inventory: string): string =>
  [
    `Sandboxed TypeScript runtime for using tools like:\n${inventory}`,
    'Before writing code, call the `skills` tool with name "execute" for how to use this tool.'
  ].join("\n\n")

const scoreCatalogTool = (
  server: CatalogServer,
  tool: Tool,
  normalized: string,
  terms: ReadonlyArray<string>
): number => {
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
  return score
}

const catalogSearchItem = (server: CatalogServer, tool: Tool, score: number) => {
  return {
    path: `${server.id}.${tool.name}`,
    server: server.id,
    serverName: server.name,
    name: tool.name,
    title: tool.title,
    description: tool.description,
    score
  }
}

export const makeGatewayCatalog = (deps: GatewayCatalogDeps) => {
  const { automationProviders, config, connectUpstream, isSuppressed } = deps

  const listPluginTools = (): Promise<ReadonlyArray<Tool>> =>
    pluginToolDefinitions(config.pluginTools)

  const enabledServers = async (projectId?: string, sessionId?: string) =>
    (await run(config.db.resolveMcpServers(projectId, sessionId))).filter(
      (server) => server.enabled && !isSuppressed(server.name)
    )

  const integrationInventory = async (projectId?: string, sessionId?: string): Promise<string> => {
    const enabled = await enabledServers(projectId, sessionId)
    const builtins = Object.keys(BUILTIN_CAPABILITIES).filter((id) =>
      enabled.some((server) => server.id === id)
    )
    const names = [
      ...enabled
        .filter((server) => !(server.id in BUILTIN_CAPABILITIES))
        .map((server) => server.name.trim()),
      ...(await listPluginTools()).map((tool) => tool.name.slice(0, tool.name.lastIndexOf(".")))
    ]
      .filter((name, index, all) => name.length > 0 && all.indexOf(name) === index)
      .toSorted((left, right) => left.localeCompare(right))
    const shown = names.slice(0, INTEGRATION_LIMIT)
    const more = names.length - shown.length
    return [
      ...builtins.map((id) => `- ${BUILTIN_CAPABILITIES[id]}`),
      ...(names.length === 0
        ? []
        : [`- Integrations: ${shown.join(", ")}${more > 0 ? `, and ${more} more` : ""}.`])
    ].join("\n")
  }

  const builtinSkills: ReadonlyArray<BuiltinSkill> = [
    executeSkill,
    ...automationSkills(),
    ...(config.packagedSkills ?? []).map((skill) =>
      packagedSkill({
        name: skill.name,
        path: () => skill.path,
        summary: skill.summary,
        composer: skill.composer
      })
    )
  ]

  const botChatKind = async (
    sessionId: string | undefined
  ): Promise<"conversational" | "plain" | undefined> => {
    if (sessionId === undefined) return undefined
    const bot = await run(config.db.findBotOwning({ sessionId })).catch(() => undefined)
    if (bot === undefined || bot.sessionId.toLowerCase() !== sessionId.toLowerCase()) {
      return undefined
    }
    return bot.conversational ? "conversational" : "plain"
  }

  const hiddenCodevisorTools = async (sessionId: string): Promise<ReadonlySet<string>> => {
    const kind = await botChatKind(sessionId)
    if (kind === "conversational") return new Set()
    return kind === "plain" ? CODEVISOR_CONVERSATIONAL_BOT_TOOL_NAMES : CODEVISOR_BOT_TOOL_NAMES
  }

  const providerTools = async (
    provider: AutomationToolProvider,
    sessionId: string | undefined
  ): Promise<ReadonlyArray<Tool>> => {
    if (provider.id !== "codevisor" || sessionId === undefined) return provider.tools
    const hidden = await hiddenCodevisorTools(sessionId)
    return provider.tools.filter((tool) => !hidden.has(tool.name))
  }

  const sessionSkills = async (
    projectId?: string,
    sessionId?: string
  ): Promise<ReadonlyArray<SkillEntry>> => {
    const enabledIds = new Set(
      (await enabledServers(projectId, sessionId)).map((server) => server.id)
    )
    if (enabledIds.has("codevisor") && (await botChatKind(sessionId)) === "conversational") {
      enabledIds.add("bot")
    }
    return skillEntries(
      builtinSkills,
      { enabledIds, pluginTools: await listPluginTools() },
      config.skillSource
    )
  }

  const allTools = async (
    projectId?: string,
    sessionId?: string
  ): Promise<ReadonlyArray<{ server: CatalogServer; tool: Tool }>> => {
    const enabled = await enabledServers(projectId, sessionId)
    const results = await Promise.allSettled(
      enabled.map(async (server) => {
        const provider = automationProviders.get(server.id)
        if (provider === undefined) {
          return { server, tools: (await connectUpstream(server.id)).tools }
        }
        return { server, tools: await providerTools(provider, sessionId) }
      })
    )
    return [
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
    (await run(config.db.resolveMcpServers(projectId, sessionId))).some(
      (candidate) => candidate.id === serverId && candidate.enabled && !isSuppressed(candidate.name)
    )

  const searchCatalog = async (
    projectId: string | undefined,
    sessionId: string | undefined,
    query: string,
    limit = 12
  ) => {
    const normalized = query.trim().toLowerCase()
    const terms = normalized.split(/[^a-z0-9]+/).filter((term) => term.length > 1)
    const ranked = (await allTools(projectId, sessionId))
      .map(({ server, tool }) => {
        return catalogSearchItem(server, tool, scoreCatalogTool(server, tool, normalized, terms))
      })
      .filter((item) => normalized.length === 0 || item.score > 0)
      .toSorted((left, right) => right.score - left.score || left.path.localeCompare(right.path))
    return {
      items: ranked.slice(0, Math.max(1, Math.min(limit, 50))),
      total: ranked.length,
      workflow:
        "Choose a match, inspect it with tools.describe.tool({ path }), then call tools[path](args). Do not stop after discovery when the user asked for an action or answer."
    }
  }

  const describeCatalogPath = async (
    projectId: string | undefined,
    sessionId: string | undefined,
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
    let serverTools: ReadonlyArray<Tool>
    if (provider === undefined) serverTools = (await connectUpstream(serverId)).tools
    else serverTools = await providerTools(provider, sessionId)
    const definition = serverTools.find((candidate) => candidate.name === toolName)
    if (definition === undefined) throw new Error(`Tool not found: ${path}`)
    return definition
  }

  return {
    allTools,
    describeCatalogPath,
    gatewayServerAllowed,
    integrationInventory,
    listPluginTools,
    searchCatalog,
    sessionSkills
  }
}
