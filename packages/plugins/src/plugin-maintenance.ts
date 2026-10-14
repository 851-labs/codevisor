import type { PluginScan } from "./plugin-store.js"
import type { PluginSupervisor } from "./plugin-supervisor.js"

export interface PluginMaintenanceConfig {
  readonly scan: () => PluginScan
  readonly isEnabled: (pluginId: string) => boolean
  readonly isClosing: () => boolean
  readonly supervisor: Pick<PluginSupervisor, "ensureRunning" | "state">
  readonly sleep?: ((ms: number) => Promise<void>) | undefined
  readonly log?: ((message: string) => void) | undefined
}

export interface PluginMaintenance {
  readonly maintain: (pluginId: string) => Promise<void>
  readonly request: (pluginId: string) => void
}

export const makePluginMaintenance = (config: PluginMaintenanceConfig): PluginMaintenance => {
  const { isClosing, isEnabled, scan, supervisor } = config
  const sleep =
    config.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)))
  const maintaining = new Set<string>()
  const maintain = async (pluginId: string): Promise<void> => {
    if (maintaining.has(pluginId) || isClosing() || !isEnabled(pluginId)) {
      return
    }
    maintaining.add(pluginId)
    try {
      while (!isClosing()) {
        const plugin = scan().plugins.find((candidate) => candidate.id === pluginId)
        if (
          plugin === undefined ||
          !isEnabled(pluginId) ||
          supervisor.state(pluginId) === "failed"
        ) {
          return
        }
        try {
          await supervisor.ensureRunning(plugin)
          return
        } catch {
          if (supervisor.state(pluginId) === "failed") {
            return
          }
          await sleep(500)
        }
      }
    } finally {
      maintaining.delete(pluginId)
    }
  }
  return {
    maintain,
    request: (pluginId) => {
      void maintain(pluginId).catch((cause: unknown) => {
        config.log?.(`Plugin ${pluginId} maintenance failed: ${String(cause)}`)
      })
    }
  }
}
