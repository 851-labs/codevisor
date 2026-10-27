import type { PluginCatalogEntry } from "@codevisor/api"
import type { McpCatalogResolver } from "@codevisor/mcp"
import {
  makeCatalog,
  makeRegistryClient,
  officialRegistryUrl,
  registryServersOf,
  type PluginCatalog as CatalogSource
} from "@codevisor/plugins"

export interface PluginCatalog {
  readonly entries: () => ReadonlyArray<PluginCatalogEntry>
  readonly entry: (id: string) => PluginCatalogEntry | undefined
  readonly search: (query: string | undefined) => Promise<ReadonlyArray<PluginCatalogEntry>>
  readonly resolve: (id: string) => Promise<PluginCatalogEntry | undefined>
  readonly refreshPublished: (cloudUrl: string | undefined) => Promise<void>
  readonly resolver: McpCatalogResolver
}

export interface PluginCatalogOptions {
  readonly dev: boolean
  readonly execPath: string
  readonly registryUrl?: string
  readonly fetch?: typeof fetch
  readonly moduleDirectory?: string
}

export const makePluginCatalog = (options: PluginCatalogOptions): PluginCatalog => {
  const source: CatalogSource = makeCatalog({
    dev: options.dev,
    execPath: options.execPath,
    ...(options.moduleDirectory === undefined ? {} : { moduleDirectory: options.moduleDirectory }),
    registry: makeRegistryClient({
      baseUrl: options.registryUrl ?? officialRegistryUrl,
      ...(options.fetch === undefined ? {} : { fetch: options.fetch })
    })
  })
  return {
    entries: source.entries,
    entry: source.entry,
    search: source.search,
    resolve: source.resolve,
    refreshPublished: async (cloudUrl) => {
      if (cloudUrl === undefined) return
      const servers = registryServersOf(await publishedCatalog(cloudUrl, options.fetch ?? fetch))
      if (servers.length > 0) source.publish(servers)
    },
    resolver: { launch: source.bundledLaunch }
  }
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
