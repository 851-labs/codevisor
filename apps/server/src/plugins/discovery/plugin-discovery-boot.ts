import type { ShownPluginSetup } from "@codevisor/db"

import type { SessionEventOutbox } from "../../routes/session-event-outbox.js"
import {
  appendAndPublish,
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "../../server-context.js"
import type { PluginEvents } from "../events/plugin-events.js"
import { authOf, makePluginDirectory, type PluginDirectory } from "./plugin-directory.js"
import { makePluginSetupBroker, type PluginSetupBroker, type ShownSetup } from "./plugin-setup.js"

export interface PluginDiscovery {
  readonly directory: PluginDirectory
  readonly setup: PluginSetupBroker
  readonly close: () => void
}

export const startPluginDiscovery = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  events: PluginEvents | undefined,
  outbox: SessionEventOutbox,
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
    notify: (sessionId, event) => outbox.deliver(sessionId, event),
    prepare: async (target) => {
      if (target.server === undefined || authOf(target) !== "mcpOAuth") return
      await mcp.beginOAuth(target.server.id)
    },
    pending: async () => (await run(services.db.listPendingPluginSetups)).map(shownSetup)
  })
  void setup.adoptPending().catch(swallowError)
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

const shownSetup = ({ id, sessionId, request }: ShownPluginSetup): ShownSetup => ({
  setupId: id,
  sessionId,
  request
})
