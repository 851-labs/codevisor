import type { SessionEventOutbox } from "../routes/session-event-outbox.js"
import { publishSyncEntries } from "../routes/sync-reconcilers.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "../server-context.js"
import { PLUGIN_ACCOUNTS_NAMESPACE } from "./accounts/plugin-account-store.js"
import { startPluginDiscovery } from "./discovery/plugin-discovery-boot.js"
import { startPluginEvents } from "./events/plugin-events-boot.js"

export const startPlugins = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  outbox: SessionEventOutbox,
  config: Pick<CodevisorServerConfig, "id" | "name">
): (() => void) => {
  routeState.pluginEvents = startPluginEvents(services, outbox)
  routeState.pluginDiscovery = startPluginDiscovery(services, fanout, routeState.pluginEvents, {
    id: config.id,
    name: config.name
  })
  const unsubscribeAccounts = services.pluginPlatform?.onAccountsChanged((entries) =>
    publishSyncEntries(services, fanout, PLUGIN_ACCOUNTS_NAMESPACE, entries)
  )
  return () => {
    routeState.pluginEvents?.close()
    routeState.pluginDiscovery?.close()
    unsubscribeAccounts?.()
  }
}
