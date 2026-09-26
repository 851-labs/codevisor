import { codevisorSandboxSignatures, type AutomationToolProvider } from "@codevisor/automation"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

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
  /// Machine-local suppression (the per-machine disable overlay). The
  /// catalog consults it everywhere it consults `enabled`: a suppressed
  /// server is not advertised, not listed, and not callable — including
  /// built-in automation providers, which never pass through
  /// `connectUpstream` and would otherwise leak their tools.
  readonly isSuppressed: (name: string) => boolean
}

const DESCRIPTION_GUIDANCE = [
  "`description` is the label the user sees for this run. Write a short, plain-text, present-tense phrase that starts with a verb and names what the code does (at most 80 characters; longer labels are cut).",
  'Good: "Find open Linear issues assigned to me", "Build the macOS app on MacBook", "Create an agent for each failing test".',
  'Bad: "Running code" (says nothing), "I\'ll search Linear for your issues" (not a verb-first label), "`linear.list_issues` + filter()" (code, not prose).'
].join("\n")

/// Standing instructions every agent Codevisor starts receives (see
/// ToolGatewayConfig.instructions). Harnesses may defer MCP tool descriptions,
/// so the choice between Codevisor agents and built-in subagents lives here.
export const CODEVISOR_AGENT_INSTRUCTIONS = [
  'You are running inside Codevisor. Its `execute` tool (MCP server "codevisor") reaches the user\'s integrations, their other machines, their open Codevisor windows, and Codevisor itself; the codevisor, codevisor-agents, codevisor-machines, and codevisor-clients skills explain how.',
  "",
  "When work could go to another agent, these usually fit best:",
  "- Your built-in subagents, for help with your current task (exploring the code, research, a quick review, small edits). Nothing is left behind for the user to manage.",
  "- A new Codevisor chat in the current workspace, for another agent working on the same change beside you when that adds something your subagents can't, like a different harness or model or a conversation the user may want to follow. It shares your checkout, so a scoped task and not editing the same files at once keep things clean.",
  "- A new Codevisor workspace with its own worktree, for separate pieces of work that each end in their own branch or PR, such as one agent per issue. Each one shows up in the user's sidebar, so they can follow it, jump in, and open or review its PR, which a hidden worktree can't offer."
].join("\n")

/// Always in context (skills load only when chosen), so this is where models
/// learn to pick Codevisor agents over their built-in subagents.
const DELEGATION_GUIDANCE = [
  "Other agents: built-in subagents usually fit help with your current task; a Codevisor chat in the current workspace fits another harness or model working on the same change; a new Codevisor workspace with its own worktree fits separate work that ends in its own branch or PR. See the codevisor-agents skill."
].join(" ")

export const executeToolDescription = (inventory: string): string =>
  [
    "Primary Codevisor tool interface. Run sandboxed JavaScript or TypeScript that discovers and composes enabled integration, Browser Use, and Computer Use tools, on this machine or on the user's other machines. The isolate has no filesystem, network, process environment, or credentials.",
    'Inside code, start with `await tools.search({ query: "<intent>" })`, inspect a match with `await tools.describe.tool({ path })`, then call the exact returned path with `await tools[path](args)`. Pass an async arrow function. Call `status("…")` before slow steps so the user sees progress.',
    DESCRIPTION_GUIDANCE,
    DELEGATION_GUIDANCE,
    `Sandbox globals:\n\`\`\`ts\n${codevisorSandboxSignatures}\n\`\`\``,
    inventory
  ].join("\n\n")

/// The discovery half of the gateway, split out of mcp-gateway: what tools
/// exist (MCP servers, automation providers, plugin tools), how they are
/// advertised (the inventory string), and how paths resolve to definitions.
export const makeGatewayCatalog = (deps: GatewayCatalogDeps) => {
  const { automationProviders, config, connectUpstream, isSuppressed } = deps

  const listPluginTools = (): Promise<ReadonlyArray<Tool>> =>
    pluginToolDefinitions(config.pluginTools)

  const integrationInventory = async (projectId?: string, sessionId?: string): Promise<string> => {
    const names = (await run(config.db.resolveMcpServers(projectId, sessionId)))
      .filter((server) => server.enabled && !isSuppressed(server.name))
      .map((server) => server.name.trim())
      .filter((name) => name.length > 0)
      .toSorted((left, right) => left.localeCompare(right))
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
