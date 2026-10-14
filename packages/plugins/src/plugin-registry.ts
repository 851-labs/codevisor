import { decode, PluginRegistryIndex } from "@codevisor/api"

import { PluginsError } from "./plugins-error.js"

export const DEFAULT_PLUGIN_REGISTRY_URL = "https://cloud.codevisor.dev"

export const resolvePluginRegistryUrl = (
  env: Readonly<Record<string, string | undefined>>
): string =>
  (
    env.CODEVISOR_PLUGIN_REGISTRY_URL ??
    env.CODEVISOR_DEV_CLOUD_URL ??
    DEFAULT_PLUGIN_REGISTRY_URL
  ).replace(/\/+$/, "")

export const PLUGIN_REGISTRY_CACHE_TTL_MS = 10 * 60_000

export type PluginRegistryFetch = (input: string, init?: RequestInit) => Promise<Response>

export interface PluginRegistryClientConfig {
  readonly baseUrl: string
  readonly fetchImpl?: PluginRegistryFetch
  readonly ttlMs?: number
  readonly now?: () => number
}

export interface PluginRegistryClient {
  readonly fetchIndex: () => Promise<PluginRegistryIndex>
}

export const makePluginRegistryClient = (
  config: PluginRegistryClientConfig
): PluginRegistryClient => {
  const fetchImpl: PluginRegistryFetch =
    config.fetchImpl ?? ((input, init) => globalThis.fetch(input, init))
  const ttlMs = config.ttlMs ?? PLUGIN_REGISTRY_CACHE_TTL_MS
  const now = config.now ?? Date.now
  const indexUrl = `${config.baseUrl.replace(/\/+$/, "")}/plugins/index.json`
  let cached: { readonly index: PluginRegistryIndex; readonly fetchedAt: number } | undefined
  return {
    fetchIndex: async () => {
      if (cached !== undefined && now() - cached.fetchedAt < ttlMs) {
        return cached.index
      }
      try {
        const response = await fetchImpl(indexUrl)
        if (!response.ok) {
          throw new Error(`registry answered with status ${response.status}`)
        }
        const index = decode(PluginRegistryIndex)(await response.json())
        if (index.generatedAt !== null) {
          cached = { fetchedAt: now(), index }
        }
        return index
      } catch (cause) {
        if (cached !== undefined) {
          return cached.index
        }
        const message = cause instanceof Error ? cause.message : String(cause)
        throw new PluginsError("unavailable", `Plugin registry is unreachable: ${message}`)
      }
    }
  }
}

export const filterPluginRegistryIndex = (
  index: PluginRegistryIndex,
  query: string
): PluginRegistryIndex => {
  const needle = query.trim().toLowerCase()
  if (needle.length === 0) {
    return index
  }
  return {
    ...index,
    entries: index.entries.filter((entry) =>
      [entry.id, entry.name, entry.description ?? "", entry.repo].some((field) =>
        field.toLowerCase().includes(needle)
      )
    )
  }
}
