import type { InstalledPlugin } from "./plugin-store.js"
import type { PluginLease, PluginSupervisor } from "./plugin-supervisor.js"

export const makePluginRequestLease = (supervisor: PluginSupervisor, plugin: InstalledPlugin) => {
  let lease: PluginLease
  return {
    ensureRunning: async () => {
      lease = await supervisor.acquire(plugin)
      return lease.port
    },
    markUnreachable: () => {
      supervisor.markUnreachable(plugin.id, lease)
    },
    noteSuccess: () => {
      supervisor.noteSuccess(plugin.id, lease)
    }
  }
}
