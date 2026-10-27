import type {
  CodevisorDatabaseService,
  PendingPluginEventDelivery,
  PluginEventSubscriptionRecord
} from "@codevisor/db"

import type { PendingSessionEvent } from "../../routes/session-event-outbox.js"
import { run } from "../../server-context.js"
import { pluginEventMessage, sourceSessionIdFor } from "./plugin-event-messages.js"

export interface PluginEventOutbox {
  readonly deliver: (subscriberId: string, event: PendingSessionEvent) => Promise<void>
}

export interface PluginEventDeliveryDeps {
  readonly db: CodevisorDatabaseService
  readonly outbox: PluginEventOutbox
  readonly now: () => number
  readonly pluginName: (serverId: string) => Promise<string>
  readonly accountLabel: (serverId: string, accountId: string) => Promise<string | undefined>
  readonly onSubscriptionsChanged: () => void
}

export const maxEventsPerDay = 200

export const makePluginEventDelivery = (deps: PluginEventDeliveryDeps) => {
  let chain = Promise.resolve()

  const deliverOne = async (pending: PendingPluginEventDelivery): Promise<void> => {
    const subscription = await run(deps.db.getPluginEventSubscription(pending.subscriptionId))
    if (subscription === undefined) return
    if (await overDailyBudget(deps, subscription)) return pauseForBudget(deps, pending)

    await deps.outbox.deliver(
      subscription.sessionId,
      await sessionEvent(deps, subscription, pending)
    )
    await run(deps.db.markPluginEventDelivered(pending.subscriptionId, pending.event.id))
    if (subscription.once) await removeSubscription(deps, subscription)
  }

  const deliverAll = async (): Promise<void> => {
    for (const pending of await run(deps.db.pendingPluginEventDeliveries)) {
      await deliverOne(pending)
    }
  }

  return {
    deliverPending: (): Promise<void> => {
      chain = chain.then(deliverAll, deliverAll)
      return chain
    }
  }
}

const dayMs = 24 * 60 * 60 * 1000

const overDailyBudget = async (
  deps: PluginEventDeliveryDeps,
  subscription: PluginEventSubscriptionRecord
): Promise<boolean> => {
  const since = new Date(deps.now() - dayMs).toISOString()
  const count = await run(deps.db.countPluginEventDeliveriesSince(subscription.id, since))
  return count >= maxEventsPerDay
}

const pauseForBudget = async (
  deps: PluginEventDeliveryDeps,
  pending: PendingPluginEventDelivery
): Promise<void> => {
  await run(
    deps.db.pausePluginEventSubscription(
      pending.subscriptionId,
      `Paused after ${maxEventsPerDay} events in a day`
    )
  )
  await run(deps.db.markPluginEventDelivered(pending.subscriptionId, pending.event.id))
  deps.onSubscriptionsChanged()
}

const removeSubscription = async (
  deps: PluginEventDeliveryDeps,
  subscription: PluginEventSubscriptionRecord
): Promise<void> => {
  await run(deps.db.deletePluginEventSubscription(subscription.id))
  deps.onSubscriptionsChanged()
}

const sessionEvent = async (
  deps: PluginEventDeliveryDeps,
  subscription: PluginEventSubscriptionRecord,
  pending: PendingPluginEventDelivery
): Promise<PendingSessionEvent> => {
  const accountLabel = await labelOf(deps, subscription.serverId, pending.event.accountId)
  return {
    message: pluginEventMessage({
      pluginName: await deps.pluginName(subscription.serverId),
      ...(accountLabel === undefined ? {} : { accountLabel }),
      subscription,
      event: pending.event
    }),
    sourceSessionId: sourceSessionIdFor(subscription.serverId)
  }
}

const labelOf = (
  deps: PluginEventDeliveryDeps,
  serverId: string,
  accountId: string | undefined
): Promise<string | undefined> => {
  if (accountId === undefined) return Promise.resolve(undefined)
  return deps.accountLabel(serverId, accountId)
}
