import type { PluginScan } from "./plugin-store.js"
import type { PluginSupervisor } from "./plugin-supervisor.js"

export interface PluginMaintenanceConfig {
  readonly scan: () => PluginScan
  readonly isEnabled: (pluginId: string) => boolean
  readonly isClosing: () => boolean
  readonly supervisor: Pick<PluginSupervisor, "ensureRunning" | "state">
  /// Waits between restart attempts; defaults to a real timer.
  readonly sleep?: ((ms: number) => Promise<void>) | undefined
  readonly log?: ((message: string) => void) | undefined
}

export interface PluginMaintenance {
  /// One pass for `pluginId`; concurrent passes for the same plugin collapse.
  readonly maintain: (pluginId: string) => Promise<void>
  /// Starts a pass in the background (after a crash, a failed enable).
  readonly request: (pluginId: string) => void
}

/// Restore the invariant that every compatible installed plugin is
/// running. The supervisor owns exponential backoff and the circuit
/// breaker; this loop merely retries after each gate until the plugin runs,
/// becomes terminally failed, is uninstalled, or the server closes.
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
    // Detached, so a failed pass (the plugins folder turned unreadable) must
    // be caught here: an unhandled rejection would exit the whole server.
    // The next request (another exit, an enable, startAll) tries again.
    request: (pluginId) => {
      void maintain(pluginId).catch((cause: unknown) => {
        config.log?.(`Plugin ${pluginId} maintenance failed: ${String(cause)}`)
      })
    }
  }
}
