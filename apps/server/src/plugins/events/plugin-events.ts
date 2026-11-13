import type {
  CreatePluginEventSubscriptionRequest,
  PluginEventRecord,
  PluginEventSubscription,
  PluginEventType
} from "@codevisor/api"
import type {
  CodevisorDatabaseService,
  PluginEventStored,
  PluginEventSubscriptionRecord
} from "@codevisor/db"

import { run } from "../../server-context.js"
import {
  builtinEventSources,
  type BuiltinEventSource,
  type BuiltinEventSources
} from "./builtin-event-sources.js"
import type { PluginEventConnections } from "./plugin-event-connections.js"
import { makePluginEventDelivery, type PluginEventOutbox } from "./plugin-event-delivery.js"
import {
  makePluginEventIngest,
  type EventOccurrence,
  type PluginEventIngest
} from "./plugin-event-ingest.js"
import type { IngressUrl, PluginEventIngress } from "./plugin-event-ingress.js"
import type { EventMarker } from "./plugin-event-messages.js"
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
  readonly builtins?: ReadonlyArray<BuiltinEventSource>
  readonly accountLabel?: (serverId: string, accountId: string) => Promise<string | undefined>
  readonly webhooks?: (ingest: PluginEventIngest) => WebhookSources
  readonly ingress?: PluginEventIngress
  readonly resolveAccount?: (serverId: string, requested?: string) => Promise<string | undefined>
  readonly onSubscriptionsChanged?: (sessionId: string) => void
}

export const makePluginEvents = (deps: PluginEventsDeps): PluginEvents => {
  const builtins = builtinEventSources(deps.builtins ?? [])
  const types = makePluginEventTypes(deps.connections, builtins)
  const pluginName = pluginNameLookup(deps.connections, builtins)
  const refreshSources = (): void => {
    void sources.refresh().catch(() => undefined)
  }
  const subscriptionsChanged = (sessionId: string): void => {
    refreshSources()
    deps.onSubscriptionsChanged?.(sessionId)
  }
  const delivery = makePluginEventDelivery({
    db: deps.db,
    outbox: deps.outbox,
    now: deps.now,
    pluginName,
    eventTitle: async (serverId, eventName) => (await types.find(serverId, eventName))?.title,
    accountLabel: deps.accountLabel ?? (async () => undefined),
    marker: (subscription) => builtinMarker(builtins, subscription),
    onSubscriptionsChanged: subscriptionsChanged
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
    builtins,
    ingest,
    timers: deps.timers,
    ...(deps.webhooks === undefined ? {} : { webhooks: deps.webhooks(ingest) }),
    ...(deps.ingress === undefined ? {} : ingressHooks(deps.ingress))
  })
  const subscriptionDeps: PluginEventSubscriptionsDeps = {
    db: deps.db,
    types,
    builtins,
    pluginName
  }
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
      subscriptionsChanged(created.sessionId)
      return created
    },
    subscriptions: (sessionId) => listSubscriptions(subscriptionDeps, sessionId),
    unsubscribe: async (subscriptionId) => {
      const existing = await run(deps.db.getPluginEventSubscription(subscriptionId))
      const removed = await run(deps.db.deletePluginEventSubscription(subscriptionId))
      ingest.forgetSubscription(subscriptionId)
      if (existing !== undefined) subscriptionsChanged(existing.sessionId)
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

const ingressHooks = (ingress: PluginEventIngress) => ({
  onSourcesChanged: ingress.refresh,
  streamMeta: async (source: EventSource) => {
    if (source.accountId === undefined) return {}
    return ingress.meta(source.serverId, source.accountId)
  }
})

const withAccount = async (
  deps: PluginEventsDeps,
  types: PluginEventTypes,
  request: CreatePluginEventSubscriptionRequest
): Promise<CreatePluginEventSubscriptionRequest> => {
  if (deps.resolveAccount === undefined) return request
  const type = await types.find(request.plugin, request.event)
  if (type === undefined || builtinsOwn(deps, type.plugin)) return request
  const accountId = await deps.resolveAccount(type.plugin, request.accountId)
  return accountId === undefined ? request : { ...request, accountId }
}

const builtinMarker = (
  builtins: BuiltinEventSources,
  subscription: PluginEventSubscriptionRecord
): EventMarker | undefined => {
  const builtin = builtins.owner(subscription.serverId)
  if (builtin === undefined) return undefined
  return { label: builtin.display(subscription).label, symbolName: builtin.symbolName }
}

const builtinsOwn = (deps: PluginEventsDeps, plugin: string): boolean =>
  (deps.builtins ?? []).some((builtin) => builtin.plugin === plugin)

const pluginNameLookup =
  (connections: PluginEventConnections, builtins: BuiltinEventSources) =>
  async (serverId: string): Promise<string> =>
    builtins.owner(serverId)?.pluginName ??
    (await connections.servers()).find((server) => server.id === serverId)?.name ??
    serverId

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
