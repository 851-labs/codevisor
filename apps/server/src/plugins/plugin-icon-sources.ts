import type { PluginCatalogEntry } from "@codevisor/api"

import type { McpIconSources } from "../infra/tool-icons.js"
import type { PluginCatalog } from "./plugin-catalog.js"

type InstalledIconSources = (id: string) => Promise<McpIconSources | undefined>

type CatalogLookup = Pick<PluginCatalog, "entry">

export const pluginIconSources =
  (installed: InstalledIconSources | undefined, catalog: CatalogLookup) =>
  async (id: string): Promise<McpIconSources | undefined> => {
    const sources = await installed?.(id)
    if (sources !== undefined) return sources
    const listed = catalog.entry(id)
    return listed === undefined ? undefined : catalogIconSources(listed)
  }

const catalogIconSources = (entry: PluginCatalogEntry): McpIconSources => {
  const url = entry.url ?? entry.iconUrl
  return {
    ...(url === undefined ? {} : { url }),
    ...(entry.iconUrl === undefined ? {} : { icons: [{ src: entry.iconUrl }] }),
    ...(entry.docsUrl === undefined ? {} : { websiteUrl: entry.docsUrl })
  }
}
