import { decode, PluginRegistryIndex } from "@codevisor/api"
import { PluginsError } from "./plugins-error.js"

/// Read-through cache over the hosted plugin registry index
/// (apps/cloud serves GET /plugins/index.json). The machine fetches on the
/// clients' behalf so apps and relays never need cloud connectivity of their
/// own — the same "clients only talk to their machine" rule as everything
/// else.

/// Production registry host: the cloud worker that indexes GitHub repos
/// tagged `codevisor-plugin`.
export const DEFAULT_PLUGIN_REGISTRY_URL = "https://cloud.codevisor.dev"

/// The registry base URL, resolved the same way the server finds its other
/// cloud endpoints: an explicit override wins, dev environments fall back to
/// the local cloud worker dev.mjs already advertises (it serves the same
/// /plugins routes), and production uses the hosted instance.
export const resolvePluginRegistryUrl = (
  env: Readonly<Record<string, string | undefined>>
): string =>
  (
    env.CODEVISOR_PLUGIN_REGISTRY_URL ??
    env.CODEVISOR_DEV_CLOUD_URL ??
    DEFAULT_PLUGIN_REGISTRY_URL
  ).replace(/\/+$/, "")

/// Fresh-cache window. Long enough to keep a browse session from hammering
/// the registry, short enough that a newly tagged plugin (indexed every ~15
/// minutes) shows up promptly.
export const PLUGIN_REGISTRY_CACHE_TTL_MS = 10 * 60_000

export type PluginRegistryFetch = (input: string, init?: RequestInit) => Promise<Response>

export interface PluginRegistryClientConfig {
  readonly baseUrl: string
  /// Injectable transport for tests; defaults to global fetch.
  readonly fetchImpl?: PluginRegistryFetch
  readonly ttlMs?: number
  /// Clock override for tests.
  readonly now?: () => number
}

export interface PluginRegistryClient {
  /// The registry index: cached while fresh, refetched after the TTL, and
  /// served stale when a refresh fails. Only when nothing was ever cached
  /// does a fetch failure surface — as a typed `unavailable` error.
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
        // A never-generated index (generatedAt null — the cloud's first poll
        // hasn't run yet) is served but not cached: the registry may fill in
        // any moment, and pinning its empty answer for a whole TTL would show
        // "no plugins published" for 10 minutes on fresh dev environments.
        if (index.generatedAt !== null) {
          cached = { fetchedAt: now(), index }
        }
        return index
      } catch (cause) {
        // Stale-while-error: an expired cache entry still beats an outage.
        if (cached !== undefined) {
          return cached.index
        }
        const message = cause instanceof Error ? cause.message : String(cause)
        throw new PluginsError("unavailable", `Plugin registry is unreachable: ${message}`)
      }
    }
  }
}

/// Case-insensitive substring search over the fields the browse UI renders
/// (id, name, description, repo). A blank query is the unfiltered index;
/// `rejected` diagnostics pass through untouched so the wire shape never
/// changes.
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
