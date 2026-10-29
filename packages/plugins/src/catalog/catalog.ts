import { join } from "node:path"

import type { PluginCatalogEntry } from "@codevisor/api"

import { readLocalCatalog, type LocalCatalog, type LocalCatalogOptions } from "./local-catalog.js"
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
}

export interface PluginCatalog {
  readonly entries: () => ReadonlyArray<PluginCatalogEntry>
  readonly entry: (id: string) => PluginCatalogEntry | undefined
  readonly search: (query: string | undefined) => ReadonlyArray<PluginCatalogEntry>
  readonly bundledLaunch: (id: string) => ResolvedStdioLaunch | undefined
  readonly oauthClient: (id: string) => string | undefined
  readonly publish: (servers: ReadonlyArray<RegistryServer>) => void
}

export const makeCatalog = (options: PluginCatalogOptions): PluginCatalog => {
  const local = readLocalCatalog(options)
  let popular = local.popular
  let featured = featuredEntries(local.firstParty, popular, options.dev)

  return {
    entries: () => featured,
    entry: (id) => featured.find((candidate) => candidate.id === id),
    search: (query) => featured.filter((candidate) => matchesQuery(candidate, query)),
    bundledLaunch: (id) => bundledLaunch(local, options.execPath, id),
    oauthClient: (id) => oauthClientOf([...local.firstParty, ...popular], id),
    publish: (servers) => {
      popular = servers.filter((server) => pluginMetaOf(server)?.bundled === undefined)
      featured = featuredEntries(local.firstParty, popular, options.dev)
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

const oauthClientOf = (servers: ReadonlyArray<RegistryServer>, id: string): string | undefined => {
  const server = servers.find((candidate) => candidate.name === id)
  return server === undefined ? undefined : pluginMetaOf(server)?.oauthClient
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
