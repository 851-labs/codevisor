import type {
  CodevisorDatabaseService,
  PluginEventStored,
  PluginEventSubscriptionRecord
} from "@codevisor/db"
import { compileEventFilter, type CompiledEventFilter } from "@codevisor/plugins"

import { run } from "../../server-context.js"
import { sourceKeyOf, type EventSource } from "./plugin-event-source-key.js"
import type { PluginEventTypes } from "./plugin-event-types.js"

export interface EventOccurrence {
  readonly eventId: string
  readonly name: string
  readonly timestamp: string
  readonly data: unknown
}

export interface PluginEventIngest {
  readonly ingest: (
    source: EventSource,
    occurrences: ReadonlyArray<EventOccurrence>
  ) => Promise<number>
  readonly forgetSubscription: (subscriptionId: string) => void
}

export interface PluginEventIngestDeps {
  readonly db: CodevisorDatabaseService
  readonly types: PluginEventTypes
  readonly deliverPending: () => Promise<void>
}

export const makePluginEventIngest = (deps: PluginEventIngestDeps): PluginEventIngest => {
  const filters = new Map<string, CompiledEventFilter | undefined>()

  const filterFor = async (
    subscription: PluginEventSubscriptionRecord
  ): Promise<CompiledEventFilter | undefined> => {
    if (filters.has(subscription.id)) return filters.get(subscription.id)
    const type = await deps.types.find(subscription.serverId, subscription.eventName)
    const compiled = compileEventFilter(subscription.filter, type?.payloadSchema)
    const filter = compiled.ok ? compiled.filter : undefined
    filters.set(subscription.id, filter)
    return filter
  }

  const matchesEvent = async (
    subscription: PluginEventSubscriptionRecord,
    event: PluginEventStored
  ): Promise<boolean> => {
    const filter = await filterFor(subscription)
    if (filter === undefined) return false
    return filter.matches(event.data, filterContext(event))
  }

  const deliverEvent = async (source: EventSource, event: PluginEventStored): Promise<number> => {
    let matched = 0
    for (const subscription of await subscriptionsOf(deps.db, source)) {
      if (!(await matchesEvent(subscription, event))) continue
      await run(deps.db.addPluginEventDelivery(subscription.id, event.id))
      matched += 1
    }
    return matched
  }

  return {
    ingest: async (source, occurrences) => {
      let matched = 0
      for (const occurrence of occurrences) {
        const recorded = await run(deps.db.recordPluginEvent(occurrenceRecord(source, occurrence)))
        if (recorded.duplicate) continue
        matched += await deliverEvent(source, recorded.event)
      }
      if (matched > 0) await deps.deliverPending()
      return matched
    },
    forgetSubscription: (subscriptionId) => {
      filters.delete(subscriptionId)
    }
  }
}

const occurrenceRecord = (source: EventSource, occurrence: EventOccurrence) => ({
  serverId: source.serverId,
  ...(source.accountId === undefined ? {} : { accountId: source.accountId }),
  eventName: occurrence.name,
  sourceEventId: occurrence.eventId,
  occurredAt: occurrence.timestamp,
  data: occurrence.data
})

const subscriptionsOf = async (
  db: CodevisorDatabaseService,
  source: EventSource
): Promise<ReadonlyArray<PluginEventSubscriptionRecord>> => {
  const key = sourceKeyOf(source)
  return (await run(db.listPluginEventSubscriptions())).filter(
    (subscription) => subscription.pausedReason === undefined && sourceKeyOf(subscription) === key
  )
}

const filterContext = (event: PluginEventStored) => ({
  eventId: event.sourceEventId,
  name: event.eventName,
  timestamp: event.occurredAt,
  ...(event.accountId === undefined ? {} : { account: { id: event.accountId } })
})
