import type {
  CreatePluginEventSubscriptionRequest,
  PluginEventRecord,
  PluginEventSubscription,
  PluginEventType
} from "@codevisor/api"
import type { CodevisorDatabaseService, PluginEventStored } from "@codevisor/db"

import { run } from "../../server-context.js"
import type { PluginEventConnections } from "./plugin-event-connections.js"
import { makePluginEventDelivery, type PluginEventOutbox } from "./plugin-event-delivery.js"
import {
  makePluginEventIngest,
  type EventOccurrence,
  type PluginEventIngest
} from "./plugin-event-ingest.js"
import type { IngressUrl, PluginEventIngress } from "./plugin-event-ingress.js"
import type { EventSource } from "./plugin-event-source-key.js"
import {
  makePluginEventSources,
  type EventTimers,
  type PluginEventSources,
  type WebhookSources
} from "./plugin-event-sources.js"
import {
  createSubscription,
  listSubscriptions,
  previewSubscription,
  type PluginEventPreview,
  type PluginEventPreviewRequest,
  type PluginEventSubscriptionsDeps
} from "./plugin-event-subscriptions.js"
import { makePluginEventTypes, type PluginEventTypes } from "./plugin-event-types.js"

export interface PluginEvents {
  readonly types: (query?: string) => Promise<ReadonlyArray<PluginEventType>>
  readonly subscribe: (
    request: CreatePluginEventSubscriptionRequest
  ) => Promise<PluginEventSubscription>
  readonly subscriptions: (sessionId?: string) => Promise<ReadonlyArray<PluginEventSubscription>>
  readonly unsubscribe: (subscriptionId: string) => Promise<boolean>
  readonly preview: (request: PluginEventPreviewRequest) => Promise<PluginEventPreview>
  readonly event: (eventId: string) => Promise<PluginEventRecord | undefined>
  readonly ingest: (
    source: EventSource,
    occurrences: ReadonlyArray<EventOccurrence>
  ) => Promise<number>
  readonly activeSources: () => ReadonlyArray<EventSource>
  readonly ingressUrls: (serverId: string, accountId: string) => Promise<ReadonlyArray<IngressUrl>>
  readonly start: () => Promise<void>
  readonly close: () => void
}

export interface PluginEventsDeps {
  readonly db: CodevisorDatabaseService
  readonly connections: PluginEventConnections
  readonly outbox: PluginEventOutbox
  readonly now: () => number
  readonly timers: EventTimers
  readonly accountLabel?: (serverId: string, accountId: string) => Promise<string | undefined>
  readonly webhooks?: (ingest: PluginEventIngest) => WebhookSources
  readonly ingress?: PluginEventIngress
  readonly resolveAccount?: (serverId: string, requested?: string) => Promise<string | undefined>
}

export const makePluginEvents = (deps: PluginEventsDeps): PluginEvents => {
  const types = makePluginEventTypes(deps.connections)
  const pluginName = pluginNameLookup(deps.connections)
  const refreshSources = (): void => {
    void sources.refresh().catch(() => undefined)
  }
  const delivery = makePluginEventDelivery({
    db: deps.db,
    outbox: deps.outbox,
    now: deps.now,
    pluginName,
    accountLabel: deps.accountLabel ?? (async () => undefined),
    onSubscriptionsChanged: refreshSources
  })
  const ingest = makePluginEventIngest({
    db: deps.db,
    types,
    deliverPending: delivery.deliverPending
  })
  const sources: PluginEventSources = makePluginEventSources({
    db: deps.db,
    connections: deps.connections,
    types,
    ingest,
    timers: deps.timers,
    ...(deps.webhooks === undefined ? {} : { webhooks: deps.webhooks(ingest) }),
    ...(deps.ingress === undefined ? {} : { onSourcesChanged: deps.ingress.refresh })
  })
  const subscriptionDeps: PluginEventSubscriptionsDeps = { db: deps.db, types, pluginName }
  const unsubscribeConnections = deps.connections.subscribeConnections((serverId) => {
    types.forget(serverId)
    refreshSources()
  })

  return {
    types: types.list,
    subscribe: async (request) => {
      const created = await createSubscription(
        subscriptionDeps,
        await withAccount(deps, types, request)
      )
      refreshSources()
      return created
    },
    subscriptions: (sessionId) => listSubscriptions(subscriptionDeps, sessionId),
    unsubscribe: async (subscriptionId) => {
      const removed = await run(deps.db.deletePluginEventSubscription(subscriptionId))
      ingest.forgetSubscription(subscriptionId)
      refreshSources()
      return removed
    },
    preview: (request) => previewSubscription(subscriptionDeps, request),
    event: async (eventId) => publicEvent(await run(deps.db.getPluginEvent(eventId))),
    ingest: ingest.ingest,
    activeSources: sources.active,
    ingressUrls: async (serverId, accountId) => deps.ingress?.urls(serverId, accountId) ?? [],
    start: async () => {
      await delivery.deliverPending()
      await sources.refresh()
    },
    close: () => {
      unsubscribeConnections()
      sources.close()
    }
  }
}

const withAccount = async (
  deps: PluginEventsDeps,
  types: PluginEventTypes,
  request: CreatePluginEventSubscriptionRequest
): Promise<CreatePluginEventSubscriptionRequest> => {
  if (deps.resolveAccount === undefined) return request
  const type = await types.find(request.plugin, request.event)
  if (type === undefined) return request
  const accountId = await deps.resolveAccount(type.plugin, request.accountId)
  return accountId === undefined ? request : { ...request, accountId }
}

const pluginNameLookup =
  (connections: PluginEventConnections) =>
  async (serverId: string): Promise<string> =>
    (await connections.servers()).find((server) => server.id === serverId)?.name ?? serverId

const publicEvent = (event: PluginEventStored | undefined): PluginEventRecord | undefined => {
  if (event === undefined) return undefined
  return {
    id: event.id,
    plugin: event.serverId,
    ...(event.accountId === undefined ? {} : { accountId: event.accountId }),
    event: event.eventName,
    sourceEventId: event.sourceEventId,
    occurredAt: event.occurredAt,
    receivedAt: event.receivedAt,
    data: event.data
  }
}
