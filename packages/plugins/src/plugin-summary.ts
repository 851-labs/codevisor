import type { PluginSummary } from "@codevisor/api"
import type { InstalledPlugin } from "./plugin-store.js"
import { pluginConsentKey } from "./plugin-consent.js"

export const summarizePlugin = (
  plugin: InstalledPlugin,
  runtime: Pick<PluginSummary, "enabled" | "canRestore" | "state">
): PluginSummary => ({
  ...runtime,
  consentKey: pluginConsentKey(
    plugin.id,
    plugin.receipt?.source.url ?? plugin.path,
    plugin.receipt?.source.subpath
  ),
  ...(plugin.receipt?.source.repo === undefined ? {} : { sourceRepo: plugin.receipt.source.repo }),
  ...(plugin.manifest.ageRating === undefined ? {} : { ageRating: plugin.manifest.ageRating }),
  id: plugin.id,
  name: plugin.manifest.name,
  panes: plugin.manifest.panes,
  path: plugin.path,
  source: plugin.source,
  version: plugin.manifest.version,
  ...(plugin.manifest.description === undefined
    ? {}
    : { description: plugin.manifest.description }),
  ...(plugin.manifest.iconPath === undefined ? {} : { iconPath: plugin.manifest.iconPath }),
  ...(plugin.manifest.tools === undefined ? {} : { tools: plugin.manifest.tools })
})
