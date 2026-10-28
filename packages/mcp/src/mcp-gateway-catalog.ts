import {
  CODEVISOR_BOT_TOOL_NAMES,
  CODEVISOR_CONVERSATIONAL_BOT_TOOL_NAMES,
  codevisorToolName,
  SANDBOX_GLOBALS,
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
import { withAccountArguments } from "./mcp-plugin-accounts.js"
import { toolVisibleTo } from "./mcp-plugin-apps.js"
import { makePluginSkillReader, pluginSkillEntries } from "./mcp-plugin-skills.js"
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

interface SearchQuery {
  readonly normalized: string
  readonly terms: ReadonlyArray<string>
}

interface ScoredText {
  readonly group: string
  readonly name: string
  readonly haystack: string
}

const scoreText = (text: ScoredText, query: SearchQuery): number => {
  const group = text.group.toLowerCase()
  const name = text.name.toLowerCase()
  const haystack = text.haystack.toLowerCase()
  let score = query.normalized.length > 0 && haystack.includes(query.normalized) ? 40 : 0
  for (const term of query.terms) {
    if (group.includes(term)) score += 20
    if (name.includes(term)) score += 12
    if (haystack.includes(term)) score += 4
  }
  return score
}

const toolSearchItem = (server: CatalogServer, tool: Tool, query: SearchQuery) => ({
  kind: "tool" as const,
  path: `${server.id}.${tool.name}`,
  server: server.id,
  serverName: server.name,
  name: tool.name,
  title: tool.title,
  description: tool.description,
  score: scoreText(
    {
      group: server.name,
      name: tool.name,
      haystack: `${server.name} ${tool.name} ${tool.title ?? ""} ${tool.description ?? ""}`
    },
    query
  )
})

const skillSearchItem = (skill: SkillEntry, query: SearchQuery) => ({
  kind: "skill" as const,
  name: skill.name,
  description: skill.summary,
  next: `Read it: call the skills tool with name "${skill.name}".`,
  score: scoreText(
    { group: "skill", name: skill.name, haystack: `skill ${skill.name} ${skill.summary}` },
    query
  )
})

const globalSearchItem = (global: (typeof SANDBOX_GLOBALS)[number], query: SearchQuery) => ({
  kind: "global" as const,
  name: global.name,
  signature: global.signature,
  description: global.description,
  score: scoreText(
    {
      group: "global",
      name: global.name,
      haystack: `${global.name} ${global.signature} ${global.description}`
    },
    query
  )
})

const searchQuery = (query: string): SearchQuery => {
  const normalized = query.trim().toLowerCase()
  return { normalized, terms: normalized.split(/[^a-z0-9]+/).filter((term) => term.length > 1) }
}

const searchKey = (item: {
  readonly kind: string
  readonly name: string
  readonly path?: string
}): string => `${item.kind}:${item.path ?? item.name}`

export const makeGatewayCatalog = (deps: GatewayCatalogDeps) => {
  const { automationProviders, config, connectUpstream, isSuppressed } = deps

  const enabledServers = async (projectId?: string, sessionId?: string) =>
    (await run(config.db.resolveMcpServers(projectId, sessionId))).filter(
      (server) => server.enabled && !isSuppressed(server.name)
    )

  const integrationInventory = async (projectId?: string, sessionId?: string): Promise<string> => {
    const enabled = await enabledServers(projectId, sessionId)
    const builtins = Object.keys(BUILTIN_CAPABILITIES).filter((id) =>
      enabled.some((server) => server.id === id)
    )
    const names = enabled
      .filter((server) => !(server.id in BUILTIN_CAPABILITIES))
      .map((server) => server.name.trim())
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

  const pluginSkillReader = makePluginSkillReader({ accounts: config.accounts, connectUpstream })

  const sessionSkills = async (
    projectId?: string,
    sessionId?: string
  ): Promise<ReadonlyArray<SkillEntry>> => {
    const enabled = await enabledServers(projectId, sessionId)
    const enabledIds = new Set(enabled.map((server) => server.id))
    if (enabledIds.has("codevisor") && (await botChatKind(sessionId)) === "conversational") {
      enabledIds.add("bot")
    }
    const saved = await skillEntries(builtinSkills, { enabledIds }, config.skillSource)
    return [...saved, ...pluginSkillEntries(enabled, pluginSkillReader)]
  }

  const upstreamTools = async (server: CatalogServer): Promise<ReadonlyArray<Tool>> => {
    const tools = (await connectUpstream(server.id)).tools.filter((tool) =>
      toolVisibleTo(tool, "model")
    )
    return withAccountArguments(config.accounts, server, tools)
  }

  const allTools = async (
    projectId?: string,
    sessionId?: string
  ): Promise<ReadonlyArray<{ server: CatalogServer; tool: Tool }>> => {
    const enabled = await enabledServers(projectId, sessionId)
    const results = await Promise.allSettled(
      enabled.map(async (server) => {
        const provider = automationProviders.get(server.id)
        if (provider === undefined) return { server, tools: await upstreamTools(server) }
        return { server, tools: await providerTools(provider, sessionId) }
      })
    )
    return results.flatMap((result) =>
      result.status === "fulfilled"
        ? result.value.tools.map((tool) => ({ server: result.value.server, tool }))
        : []
    )
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
    text: string,
    limit = 12
  ) => {
    const query = searchQuery(text)
    const enabledIds = new Set(
      (await enabledServers(projectId, sessionId)).map((server) => server.id)
    )
    const globals = SANDBOX_GLOBALS.filter(
      (global) => global.gate === undefined || enabledIds.has(global.gate)
    )
    const candidates = [
      ...(await allTools(projectId, sessionId)).map(({ server, tool }) =>
        toolSearchItem(server, tool, query)
      ),
      ...(await sessionSkills(projectId, sessionId)).map((skill) => skillSearchItem(skill, query)),
      ...globals.map((global) => globalSearchItem(global, query))
    ]
    const ranked = candidates
      .filter((item) => query.normalized.length === 0 || item.score > 0)
      .toSorted(
        (left, right) => right.score - left.score || searchKey(left).localeCompare(searchKey(right))
      )
    return {
      items: ranked.slice(0, Math.max(1, Math.min(limit, 50))),
      total: ranked.length,
      workflow:
        "Choose a match. A tool: inspect it with machine.tools.describe.tool({ path }), then call machine.tools[path](args). A skill: read it with the skills tool. A global: use it as its signature shows. Do not stop after discovery when the user asked for an action or answer."
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
    const requested = path.slice(separator + 1)
    const toolName = serverId === "codevisor" ? codevisorToolName(requested) : requested
    const server = (await enabledServers(projectId, sessionId)).find(
      (candidate) => candidate.id === serverId
    )
    if (server === undefined) throw new Error("Tool server is disabled for this session")
    const provider = automationProviders.get(serverId)
    let serverTools: ReadonlyArray<Tool>
    if (provider === undefined) serverTools = await upstreamTools(server)
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
    searchCatalog,
    sessionSkills
  }
}
