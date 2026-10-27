import { join } from "node:path"

import type { PluginCatalogEntry } from "@codevisor/api"

import { readLocalCatalog, type LocalCatalog, type LocalCatalogOptions } from "./local-catalog.js"
import { latestDistinct, type RegistryClient } from "./registry-client.js"
import { catalogEntryOf, pluginMetaOf } from "./registry-entry.js"
import type { RegistryServer } from "./registry-server.js"

export interface ResolvedStdioLaunch {
  readonly transport: "stdio"
  readonly command: string
  readonly args: ReadonlyArray<string>
}

export interface PluginCatalogOptions extends LocalCatalogOptions {
  readonly dev: boolean
  readonly execPath: string
  readonly registry?: RegistryClient
}

export interface PluginCatalog {
  readonly entries: () => ReadonlyArray<PluginCatalogEntry>
  readonly entry: (id: string) => PluginCatalogEntry | undefined
  readonly search: (query: string | undefined) => Promise<ReadonlyArray<PluginCatalogEntry>>
  readonly resolve: (id: string) => Promise<PluginCatalogEntry | undefined>
  readonly bundledLaunch: (id: string) => ResolvedStdioLaunch | undefined
  readonly publish: (servers: ReadonlyArray<RegistryServer>) => void
}

export const makeCatalog = (options: PluginCatalogOptions): PluginCatalog => {
  const local = readLocalCatalog(options)
  let featured = featuredEntries(local.firstParty, local.popular, options.dev)

  const entry = (id: string) => featured.find((candidate) => candidate.id === id)

  return {
    entries: () => featured,
    entry,
    search: async (query) => {
      const matching = featured.filter((candidate) => matchesQuery(candidate, query))
      if (query === undefined || query.trim() === "" || options.registry === undefined)
        return matching
      const found = registryEntries(await options.registry.search(query.trim()))
      return [...matching, ...found.filter((candidate) => entry(candidate.id) === undefined)]
    },
    resolve: async (id) => entry(id) ?? (await registryEntry(options.registry, id)),
    bundledLaunch: (id) => bundledLaunch(local, options.execPath, id),
    publish: (servers) => {
      const firstParty = local.firstParty
      featured = featuredEntries(
        firstParty,
        servers.filter((server) => pluginMetaOf(server)?.bundled === undefined),
        options.dev
      )
    }
  }
}

const featuredEntries = (
  firstParty: ReadonlyArray<RegistryServer>,
  popular: ReadonlyArray<RegistryServer>,
  dev: boolean
): ReadonlyArray<PluginCatalogEntry> => [
  ...firstParty
    .filter((server) => dev || pluginMetaOf(server)?.devOnly !== true)
    .flatMap((server) => present(catalogEntryOf(server, "first-party"))),
  ...popular.flatMap((server) => present(catalogEntryOf(server, "popular")))
]

const registryEntries = (
  servers: ReadonlyArray<RegistryServer>
): ReadonlyArray<PluginCatalogEntry> =>
  latestDistinct(servers)
    .filter((server) => pluginMetaOf(server)?.bundled === undefined)
    .flatMap((server) => present(catalogEntryOf(server, "registry")))

const registryEntry = async (
  registry: RegistryClient | undefined,
  id: string
): Promise<PluginCatalogEntry | undefined> => {
  const server = await registry?.server(id)
  if (server === undefined || pluginMetaOf(server)?.bundled !== undefined) return undefined
  return catalogEntryOf(server, "registry")
}

const bundledLaunch = (
  local: LocalCatalog,
  execPath: string,
  id: string
): ResolvedStdioLaunch | undefined => {
  const server = local.firstParty.find((candidate) => candidate.name === id)
  const meta = server === undefined ? undefined : pluginMetaOf(server)
  if (meta?.bundled === undefined) return undefined
  return {
    transport: "stdio",
    command: execPath,
    args: [join(local.root, meta.bundled, meta.entry ?? join("dist", "main.js"))]
  }
}

const matchesQuery = (entry: PluginCatalogEntry, query: string | undefined): boolean => {
  const words = (query ?? "")
    .toLowerCase()
    .split(/\s+/)
    .filter((word) => word !== "")
  const haystack = [entry.name, entry.description, entry.publisher, entry.id]
    .join(" ")
    .toLowerCase()
  return words.every((word) => haystack.includes(word))
}

const present = <T>(value: T | undefined): ReadonlyArray<T> => (value === undefined ? [] : [value])
