import type { PluginManifest } from "@codevisor/api"
import { existsSync } from "node:fs"
import { PluginsError } from "./plugins-error.js"
import type { InstalledPlugin } from "./plugin-store.js"
import type { PluginTransactionEngine } from "./plugin-transaction.js"

export interface PluginRestore {
  readonly canRestore: (pluginId: string) => boolean
  readonly restore: (pluginId: string) => Promise<PluginManifest>
}

export const makePluginRestore = (options: {
  readonly installedWithId: (pluginId: string) => InstalledPlugin | undefined
  readonly transactions: PluginTransactionEngine
}): PluginRestore => ({
  canRestore: (pluginId) => {
    const plugin = options.installedWithId(pluginId)
    return (
      plugin?.source === "managed" && existsSync(options.transactions.paths(pluginId).knownGoodCode)
    )
  },
  restore: (pluginId) =>
    options.transactions.withLock(pluginId, async () => {
      await options.transactions.recoverPlugin(pluginId)
      const plugin = options.installedWithId(pluginId)
      if (plugin === undefined) {
        throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
      }
      if (plugin.source !== "managed") {
        throw new PluginsError("invalid", `Plugin ${pluginId} is linked and has no managed backup`)
      }
      await options.transactions.restoreKnownGood(pluginId)
      const restored = options.installedWithId(pluginId)
      /* v8 ignore next 3 -- successful verification requires the restored plugin to scan. */
      if (restored === undefined) {
        throw new PluginsError("unavailable", `Plugin ${pluginId} restore did not remain installed`)
      }
      return restored.manifest
    })
})
