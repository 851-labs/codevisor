import type { PluginCatalogEntry } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpCatalogResolver } from "@codevisor/mcp"
import {
  makeCatalog,
  registryServersOf,
  type PluginCatalog as CatalogSource
} from "@codevisor/plugins"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

export interface PluginCatalog {
  readonly entries: () => ReadonlyArray<PluginCatalogEntry>
  readonly entry: (id: string) => PluginCatalogEntry | undefined
  readonly search: (query: string | undefined) => ReadonlyArray<PluginCatalogEntry>
  readonly browse: (query: string | undefined) => Promise<ReadonlyArray<PluginCatalogEntry>>
  readonly browsable: (id: string) => Promise<PluginCatalogEntry | undefined>
  readonly refreshPublished: (cloudUrl: string | undefined) => Promise<void>
  readonly resolver: McpCatalogResolver
}

export interface PluginCatalogOptions {
  readonly dev: boolean
  readonly execPath: string
  readonly fetch?: typeof fetch
  readonly moduleDirectory?: string
  readonly enabledFlags?: () => Promise<ReadonlySet<string>>
}

export const makePluginCatalog = (options: PluginCatalogOptions): PluginCatalog => {
  const source: CatalogSource = makeCatalog({
    dev: options.dev,
    execPath: options.execPath,
    ...(options.moduleDirectory === undefined ? {} : { moduleDirectory: options.moduleDirectory })
  })
  const enabledFlags = options.enabledFlags ?? noFlags
  return {
    entries: source.entries,
    entry: source.entry,
    search: source.search,
    browse: async (query) => {
      const enabled = await enabledFlags()
      return source.search(query).filter((entry) => flagAllows(entry, enabled))
    },
    browsable: async (id) => {
      const entry = source.entry(id)
      if (entry === undefined || !flagAllows(entry, await enabledFlags())) return undefined
      return entry
    },
    refreshPublished: async (cloudUrl) => {
      if (cloudUrl === undefined) return
      const servers = registryServersOf(await publishedCatalog(cloudUrl, options.fetch ?? fetch))
      if (servers.length > 0) source.publish(servers)
    },
    resolver: { launch: source.bundledLaunch, oauthClient: source.oauthClient }
  }
}

export const enabledFeatureFlags = async (
  db: Pick<CodevisorDatabaseService, "getSyncEntries">
): Promise<ReadonlySet<string>> => {
  const entries = await Effect.runPromise(db.getSyncEntries(clientPreferencesNamespace))
  return new Set(entries.filter(isEnabledFlag).map((entry) => entry.key.slice(flagPrefix.length)))
}

export const isDevInstance = (env: NodeJS.ProcessEnv): boolean =>
  env.CODEVISOR_DEV_INSTANCE_ID !== undefined

const publishedCatalog = async (cloudUrl: string, request: typeof fetch): Promise<unknown> => {
  const response = await request(new URL("/v0/servers", cloudUrl), {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(8_000)
  }).catch(() => undefined)
  if (response?.ok !== true) return undefined
  return response.json().catch(() => undefined)
}

export const catalogRefreshMs = 60 * 60_000

export const startCatalogRefresh = (
  catalog: PluginCatalog,
  cloudUrl: () => string | undefined
): (() => void) => {
  const refresh = () => {
    void catalog.refreshPublished(cloudUrl()).catch(() => undefined)
  }
  refresh()
  const timer = setInterval(refresh, catalogRefreshMs)
  timer.unref()
  return () => clearInterval(timer)
}

const clientPreferencesNamespace = "client-preferences"
const flagPrefix = "featureFlags."

const noFlags = async (): Promise<ReadonlySet<string>> => new Set()

const flagAllows = (entry: PluginCatalogEntry, enabled: ReadonlySet<string>): boolean =>
  entry.featureFlag === undefined || enabled.has(entry.featureFlag)

const isEnabledFlag = (entry: SyncEntryRecord): boolean =>
  entry.key.startsWith(flagPrefix) && entry.value === true && entry.deleted !== true
