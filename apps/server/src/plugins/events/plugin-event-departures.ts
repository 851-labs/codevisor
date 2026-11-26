import type { CodevisorDatabaseService, PluginEventSubscriptionRecord } from "@codevisor/db"
import type { McpServerIdentity, McpServerLifecycleChange } from "@codevisor/mcp"

import { run } from "../../server-context.js"
import {
  pluginDepartureEvent,
  type EventMachine,
  type PluginDepartureKind
} from "./plugin-departure-messages.js"
import type { PluginEventOutbox } from "./plugin-event-delivery.js"

export interface PluginEventDeparturesDeps {
  readonly db: CodevisorDatabaseService
  readonly outbox: PluginEventOutbox
  readonly machine: EventMachine
  readonly forgetSubscription: (subscriptionId: string) => void
  readonly onSubscriptionsChanged: (sessionId: string) => void
}

export const handleServerLifecycle = async (
  deps: PluginEventDeparturesDeps,
  change: McpServerLifecycleChange
): Promise<void> => {
  if (change.kind === "removed") return pluginRemoved(deps, change.server, change.subscriptions)
  const held = await subscriptionsOf(deps.db, change.server.id)
  if (change.kind === "turnedOff") return tellEachSession(deps, "turnedOff", change.server, held)
  for (const sessionId of bySession(held).keys()) deps.onSubscriptionsChanged(sessionId)
}

const pluginRemoved = async (
  deps: PluginEventDeparturesDeps,
  server: McpServerIdentity,
  deleted: ReadonlyArray<PluginEventSubscriptionRecord>
): Promise<void> => {
  for (const subscription of deleted) deps.forgetSubscription(subscription.id)
  await tellEachSession(deps, "removed", server, deleted)
}

const tellEachSession = async (
  deps: PluginEventDeparturesDeps,
  kind: PluginDepartureKind,
  server: McpServerIdentity,
  subscriptions: ReadonlyArray<PluginEventSubscriptionRecord>
): Promise<void> => {
  for (const [sessionId, held] of bySession(subscriptions)) {
    deps.onSubscriptionsChanged(sessionId)
    const event = pluginDepartureEvent({ kind, server, subscriptions: held }, deps.machine)
    await deps.outbox.deliver(sessionId, event).catch(() => undefined)
  }
}

const subscriptionsOf = async (
  db: CodevisorDatabaseService,
  serverId: string
): Promise<ReadonlyArray<PluginEventSubscriptionRecord>> =>
  (await run(db.listPluginEventSubscriptions())).filter(
    (subscription) => subscription.serverId === serverId
  )

const bySession = (
  subscriptions: ReadonlyArray<PluginEventSubscriptionRecord>
): ReadonlyMap<string, ReadonlyArray<PluginEventSubscriptionRecord>> =>
  Map.groupBy(subscriptions, (subscription) => subscription.sessionId)
