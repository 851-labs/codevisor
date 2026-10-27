import type {
  McpServer,
  PluginCapabilities,
  PluginCatalogEntry,
  PluginEventType,
  PluginSetupRequest
} from "@codevisor/api"

import type { PluginCatalog } from "../plugin-catalog.js"

export type PluginAuth = PluginSetupRequest["auth"]

export interface PluginDirectoryItem {
  readonly plugin: string
  readonly name: string
  readonly description?: string
  readonly installed: boolean
  readonly enabled: boolean
  readonly ready: boolean
  readonly auth: PluginAuth
  readonly accounts: ReadonlyArray<string>
  readonly tools: ReadonlyArray<string>
  readonly events: ReadonlyArray<string>
  readonly skills: ReadonlyArray<string>
  readonly panes: ReadonlyArray<string>
}

export interface PluginDirectoryDeps {
  readonly catalog: PluginCatalog
  readonly servers: () => Promise<ReadonlyArray<McpServer>>
  readonly accountLabels: (serverId: string) => Promise<ReadonlyArray<string>>
  readonly tools: (serverId: string) => Promise<ReadonlyArray<DescribedTool>>
  readonly eventTypes: () => Promise<ReadonlyArray<PluginEventType>>
}

export interface DescribedTool {
  readonly name: string
  readonly description?: string | undefined
  readonly inputSchema: unknown
}

export interface PluginTarget {
  readonly plugin: string
  readonly server?: McpServer
  readonly entry?: PluginCatalogEntry
}

export const makePluginDirectory = (deps: PluginDirectoryDeps) => {
  const itemFor = async (target: PluginTarget): Promise<PluginDirectoryItem> => {
    const accounts = await accountLabelsOf(target)
    const capabilities = capabilitiesOf(target)
    return {
      plugin: target.server?.id ?? target.plugin,
      name: target.server?.name ?? target.entry!.name,
      ...descriptionOf(target),
      installed: target.server !== undefined,
      enabled: target.server?.enabled ?? false,
      ready: isReady(target, accounts),
      auth: authOf(target),
      accounts,
      tools: capabilities.tools.map((tool) => tool.name),
      events: capabilities.events.map((event) => event.name),
      skills: capabilities.skills.map((skill) => skill.name),
      panes: capabilities.panes.map((pane) => pane.title)
    }
  }

  const accountLabelsOf = async (target: PluginTarget): Promise<ReadonlyArray<string>> => {
    if (target.server === undefined) return []
    return deps.accountLabels(target.server.id)
  }

  const targets = async (query?: string): Promise<ReadonlyArray<PluginTarget>> => {
    const servers = (await deps.servers()).filter((server) => server.kind === "managed")
    const installed = servers.map((server) => targetOfServer(deps.catalog, server))
    const installedCatalog = new Set(servers.map((server) => server.catalogId))
    const available = (await deps.catalog.search(query))
      .filter((entry) => !installedCatalog.has(entry.id))
      .map((entry) => ({ plugin: entry.id, entry }))
    return [...installed, ...available]
  }

  const find = async (plugin: string): Promise<PluginTarget | undefined> => {
    const local = (await targets()).find((target) => namesTarget(target, plugin))
    if (local !== undefined) return local
    const entry = await deps.catalog.resolve(plugin)
    return entry === undefined ? undefined : { plugin: entry.id, entry }
  }

  return {
    find,
    item: itemFor,
    search: async (query: string | undefined): Promise<ReadonlyArray<PluginDirectoryItem>> => {
      const items = await Promise.all((await targets(query)).map(itemFor))
      return items.filter((item) => matchesQuery(item, query))
    },
    describe: async (plugin: string) => {
      const target = await find(plugin)
      if (target === undefined) return undefined
      return {
        ...(await itemFor(target)),
        ...(target.entry?.accounts === undefined ? {} : { accountSpec: publicSpec(target.entry) }),
        toolDetails: await toolDetails(deps, target),
        eventDetails: (await deps.eventTypes()).filter((type) => type.plugin === target.server?.id)
      }
    }
  }
}

export type PluginDirectory = ReturnType<typeof makePluginDirectory>

export const authOf = (target: PluginTarget): PluginAuth => {
  const accounts = target.entry?.accounts
  if (accounts?.oauth !== undefined) return "oauth2"
  if (accounts !== undefined) return "fields"
  if (target.server?.authType === "oauth") return "mcpOAuth"
  return "none"
}

export const isReady = (target: PluginTarget, accounts: ReadonlyArray<string>): boolean => {
  const server = target.server
  if (server === undefined || !server.enabled) return false
  const auth = authOf(target)
  if (auth === "fields" || auth === "oauth2") return accounts.length > 0
  if (auth === "mcpOAuth") return server.connectionState === "connected"
  return true
}

export const capabilitiesOf = (target: PluginTarget): PluginCapabilities =>
  target.server?.capabilities ?? target.entry?.capabilities ?? emptyCapabilities

const emptyCapabilities: PluginCapabilities = {
  tools: [],
  events: [],
  skills: [],
  panes: [],
  ingress: []
}

const targetOfServer = (catalog: PluginCatalog, server: McpServer): PluginTarget => {
  const entry = server.catalogId === undefined ? undefined : catalog.entry(server.catalogId)
  return { plugin: server.id, server, ...(entry === undefined ? {} : { entry }) }
}

const descriptionOf = (target: PluginTarget): { readonly description?: string } =>
  target.entry === undefined ? {} : { description: target.entry.description }

const namesTarget = (target: PluginTarget, plugin: string): boolean => {
  const wanted = plugin.trim().toLowerCase()
  return [
    target.plugin,
    target.server?.id,
    target.server?.name,
    target.entry?.id,
    target.entry?.name
  ]
    .filter((name): name is string => name !== undefined)
    .some((name) => name.toLowerCase() === wanted)
}

const matchesQuery = (item: PluginDirectoryItem, query: string | undefined): boolean => {
  const words = (query ?? "")
    .toLowerCase()
    .split(/\s+/)
    .filter((word) => word !== "")
  if (words.length === 0) return true
  const haystack = [
    item.name,
    item.description ?? "",
    ...item.tools,
    ...item.events,
    ...item.skills
  ]
    .join(" ")
    .toLowerCase()
  return words.some((word) => haystack.includes(word))
}

const toolDetails = async (
  deps: PluginDirectoryDeps,
  target: PluginTarget
): Promise<ReadonlyArray<DescribedTool>> => {
  if (target.server === undefined || !target.server.enabled)
    return capabilitiesOf(target).tools.map(digestTool)
  return deps.tools(target.server.id).catch(() => capabilitiesOf(target).tools.map(digestTool))
}

const digestTool = (tool: PluginCapabilities["tools"][number]): DescribedTool => ({
  name: tool.name,
  ...(tool.description === undefined ? {} : { description: tool.description }),
  inputSchema: {}
})

const publicSpec = (entry: PluginCatalogEntry) => ({
  label: entry.accounts!.label,
  ...(entry.accounts!.oauth === undefined
    ? {}
    : {
        oauth: { provider: entry.accounts!.oauth.provider, scopes: entry.accounts!.oauth.scopes }
      }),
  fields: entry.accounts!.fields.map((field) => ({
    key: field.key,
    label: field.label,
    type: field.type,
    required: field.required
  }))
})
