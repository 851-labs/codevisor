import {
  isRecord,
  parseRegistryServer,
  registryServersOf,
  type RegistryServer
} from "./registry-server.js"

export interface RegistryClient {
  readonly search: (query: string) => Promise<ReadonlyArray<RegistryServer>>
  readonly server: (name: string) => Promise<RegistryServer | undefined>
}

export interface RegistryClientOptions {
  readonly baseUrl: string
  readonly fetch?: typeof fetch
  readonly now?: () => number
  readonly limit?: number
}

export const officialRegistryUrl = "https://registry.modelcontextprotocol.io"
export const registryCacheMs = 10 * 60_000
export const registryTimeoutMs = 8_000

export const makeRegistryClient = (options: RegistryClientOptions): RegistryClient => {
  const request = options.fetch ?? fetch
  const now = options.now ?? Date.now
  const cache = new Map<string, { readonly at: number; readonly body: unknown }>()

  const getJson = async (path: string): Promise<unknown> => {
    const hit = cache.get(path)
    if (hit !== undefined && now() - hit.at < registryCacheMs) return hit.body
    const response = await request(new URL(path, options.baseUrl), {
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(registryTimeoutMs)
    })
    if (!response.ok) return undefined
    const body: unknown = await response.json()
    cache.set(path, { at: now(), body })
    return body
  }

  return {
    search: async (query) => {
      const params = new URLSearchParams({
        search: query,
        version: "latest",
        limit: String(options.limit ?? 30)
      })
      return registryServersOf(
        await getJson(`/v0/servers?${params.toString()}`).catch(() => undefined)
      )
    },
    server: async (name) => {
      const body = await getJson(`/v0/servers/${encodeURIComponent(name)}/versions/latest`).catch(
        () => undefined
      )
      return parseRegistryServer(isRecord(body) ? body.server : undefined)
    }
  }
}

export const latestDistinct = (
  servers: ReadonlyArray<RegistryServer>
): ReadonlyArray<RegistryServer> => {
  const byName = new Map<string, RegistryServer>()
  for (const server of servers) byName.set(server.name, server)
  return [...byName.values()]
}
