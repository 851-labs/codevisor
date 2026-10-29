import { parseCatalog, type CatalogPlugin } from "./plugin-catalog"

export type PluginLookup = CatalogPlugin | "missing" | null

export const pluginIndexPath = "/plugins.json"

export const pluginPath = (name: string): string => `/plugins/${encodeURIComponent(name)}`

export const fetchCatalog = async (): Promise<ReadonlyArray<CatalogPlugin> | null> => {
  try {
    const response = await fetch(new URL("/v0/servers", cloudBaseUrl()), {
      ...edgeCache,
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(fetchTimeoutMs)
    })
    if (!response.ok) return null
    return parseCatalog(await response.json())
  } catch {
    return null
  }
}

export const loadPlugin = async (name: string): Promise<PluginLookup> => {
  const plugins = await fetchCatalog()
  if (plugins === null) return null
  return plugins.find((plugin) => plugin.name === name) ?? "missing"
}

const fetchTimeoutMs = 10_000
const edgeCacheSeconds = 300

const edgeCache = {
  cf: { cacheEverything: true, cacheTtlByStatus: { "200-299": edgeCacheSeconds } }
}

const cloudBaseUrl = (): string =>
  (import.meta.env.VITE_CODEVISOR_DEV_CLOUD_URL ?? "https://cloud.codevisor.dev").replace(
    /\/+$/,
    ""
  )
