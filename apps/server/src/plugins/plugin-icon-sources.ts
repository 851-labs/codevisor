import type { PluginCatalogEntry } from "@codevisor/api"

import type { McpIconSources } from "../infra/tool-icons.js"
import type { PluginCatalog } from "./plugin-catalog.js"

type InstalledIconSources = (
  id: string
) => Promise<(McpIconSources & { readonly catalogId?: string }) | undefined>

type CatalogLookup = Pick<PluginCatalog, "entry">

export const pluginIconSources =
  (installed: InstalledIconSources | undefined, catalog: CatalogLookup) =>
  async (id: string): Promise<McpIconSources | undefined> => {
    const sources = await installed?.(id)
    if (sources !== undefined && ownsIcon(sources)) return sources

    const listed = catalog.entry(sources?.catalogId ?? id)
    if (listed === undefined) return sources

    return catalogIconSources(listed)
  }

const ownsIcon = (sources: McpIconSources): boolean =>
  sources.url !== undefined || sources.icons !== undefined

const catalogIconSources = (entry: PluginCatalogEntry): McpIconSources => {
  const url = entry.url ?? entry.iconUrl
  return {
    ...(url === undefined ? {} : { url }),
    ...(entry.iconUrl === undefined ? {} : { icons: [{ src: entry.iconUrl }] }),
    ...(entry.docsUrl === undefined ? {} : { websiteUrl: entry.docsUrl })
  }
}
