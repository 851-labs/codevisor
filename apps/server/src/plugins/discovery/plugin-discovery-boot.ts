import {
  appendAndPublish,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "../../server-context.js"
import type { PluginEvents } from "../events/plugin-events.js"
import { makePluginDirectory, type PluginDirectory } from "./plugin-directory.js"
import { makePluginSetupBroker, type PluginSetupBroker } from "./plugin-setup.js"

export interface PluginDiscovery {
  readonly directory: PluginDirectory
  readonly setup: PluginSetupBroker
  readonly close: () => void
}

export const startPluginDiscovery = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  events: PluginEvents | undefined,
  machine: { readonly id: string; readonly name: string }
): PluginDiscovery | undefined => {
  const { mcp, pluginCatalog, pluginPlatform } = services
  if (mcp === undefined || pluginCatalog === undefined) return undefined
  const directory = makePluginDirectory({
    catalog: pluginCatalog,
    servers: () => mcp.list(),
    accountLabels: async (serverId) =>
      ((await pluginPlatform?.accounts.choices(serverId).catch(() => [])) ?? []).map(
        (choice) => choice.label
      ),
    tools: async (serverId) => mcp.tools(serverId),
    eventTypes: async () => (await events?.types()) ?? []
  })
  const setup = makePluginSetupBroker({
    directory,
    machine,
    emit: async (sessionId, payload) => {
      await appendAndPublish(services.db, fanout, "session.output", sessionId, payload)
    },
    wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref())
  })
  const refresh = () => {
    void setup.refresh().catch(swallowError)
  }
  const unsubscribers = [
    mcp.subscribeServersChanged(refresh),
    pluginPlatform?.onAccountsChanged(refresh)
  ]
  return {
    directory,
    setup,
    close: () => {
      for (const unsubscribe of unsubscribers) unsubscribe?.()
    }
  }
}
