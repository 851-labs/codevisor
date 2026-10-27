import { decode, PluginCapabilities } from "@codevisor/api"

export type CatalogSource = "first-party" | "popular"

export interface CatalogPlugin {
  readonly name: string
  readonly title: string
  readonly publisher: string
  readonly description: string
  readonly version: string
  readonly source: CatalogSource
  readonly iconUrl: string | undefined
  readonly websiteUrl: string | undefined
  readonly remoteUrl: string | undefined
  readonly ageRating: number | undefined
  readonly capabilities: PluginCapabilities | undefined
}

export const catalogBaseUrl = (): string =>
  (import.meta.env.VITE_CODEVISOR_DEV_CLOUD_URL ?? "https://cloud.codevisor.dev").replace(
    /\/+$/,
    ""
  )

export const pluginPath = (name: string): string => `/plugins/${encodeURIComponent(name)}`

export const reportHref = (plugin: CatalogPlugin): string =>
  `mailto:${reportAddress}?subject=${encodeURIComponent(`Report plugin: ${plugin.title} (${plugin.name})`)}`

export const fetchCatalog = async (): Promise<ReadonlyArray<CatalogPlugin> | null> => {
  try {
    const response = await fetch(`${catalogBaseUrl()}/v0/servers`, {
      signal: AbortSignal.timeout(catalogTimeoutMs)
    })
    if (!response.ok) return null
    return parseCatalog(await response.json())
  } catch {
    return null
  }
}

export const parseCatalog = (body: unknown): ReadonlyArray<CatalogPlugin> => {
  if (!isObject(body) || !Array.isArray(body.servers)) throw new Error("Malformed plugin catalog")
  return body.servers.flatMap(catalogPlugin)
}

type Json = Readonly<Record<string, unknown>>

const catalogTimeoutMs = 10_000
const reportAddress = "hello@codevisor.dev"
const firstPartyNamespace = "dev.codevisor"
const codevisorMetaKey = "dev.codevisor/plugin"

const catalogPlugin = (item: unknown): ReadonlyArray<CatalogPlugin> => {
  const server = isObject(item) ? item.server : undefined
  if (!isObject(server)) return []

  const name = stringField(server, "name")
  if (name === undefined) return []

  return [toCatalogPlugin(name, server)]
}

const toCatalogPlugin = (name: string, server: Json): CatalogPlugin => {
  const meta = codevisorMeta(server)
  return {
    name,
    title: stringField(server, "title") ?? name,
    publisher: stringField(meta, "publisher") ?? defaultPublisher(name),
    description: stringField(server, "description") ?? "",
    version: stringField(server, "version") ?? "",
    source: sourceOf(name),
    iconUrl: firstHttpsUrl(server.icons, "src"),
    websiteUrl: httpsUrl(stringField(server, "websiteUrl")),
    remoteUrl: firstHttpsUrl(server.remotes, "url"),
    ageRating: numberField(meta, "ageRating"),
    capabilities: capabilitiesOf(meta.capabilities)
  }
}

const namespaceOf = (name: string): string => name.split("/")[0] ?? name

const sourceOf = (name: string): CatalogSource => {
  if (namespaceOf(name) === firstPartyNamespace) return "first-party"
  return "popular"
}

const defaultPublisher = (name: string): string => {
  if (sourceOf(name) === "first-party") return "Codevisor"
  return namespaceOf(name).split(".").toReversed().join(".")
}

const codevisorMeta = (server: Json): Json => {
  const meta = isObject(server._meta) ? server._meta[codevisorMetaKey] : undefined
  return isObject(meta) ? meta : {}
}

const capabilitiesOf = (value: unknown): PluginCapabilities | undefined => {
  if (value === undefined) return undefined
  try {
    return decode(PluginCapabilities)(value)
  } catch {
    return undefined
  }
}

const firstHttpsUrl = (list: unknown, key: string): string | undefined => {
  if (!Array.isArray(list)) return undefined
  const first: unknown = list[0]
  return isObject(first) ? httpsUrl(stringField(first, key)) : undefined
}

const httpsUrl = (value: string | undefined): string | undefined =>
  isHttpsUrl(value) ? value : undefined

const isHttpsUrl = (value: string | undefined): value is string =>
  value !== undefined && value.startsWith("https://") && URL.canParse(value)

const isObject = (value: unknown): value is Json =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const stringField = (object: Json, key: string): string | undefined => {
  const value = object[key]
  return typeof value === "string" && value.length > 0 ? value : undefined
}

const numberField = (object: Json, key: string): number | undefined => {
  const value = object[key]
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}
