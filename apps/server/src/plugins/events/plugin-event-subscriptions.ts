import type {
  CreatePluginEventSubscriptionRequest,
  PluginEventSubscription,
  PluginEventType
} from "@codevisor/api"
import type { CodevisorDatabaseService, PluginEventSubscriptionRecord } from "@codevisor/db"
import { compileEventFilter, type EventFilterAccepted } from "@codevisor/plugins"

import { HttpFailure, run } from "../../server-context.js"
import type { PluginEventTypes } from "./plugin-event-types.js"

export interface PluginEventPreviewRequest {
  readonly plugin: string
  readonly event: string
  readonly filter?: string
  readonly accountId?: string
}

export interface PluginEventPreview {
  readonly explained: string
  readonly scanned: number
  readonly matched: ReadonlyArray<{ readonly eventId: string; readonly occurredAt: string }>
}

export interface PluginEventSubscriptionsDeps {
  readonly db: CodevisorDatabaseService
  readonly types: PluginEventTypes
  readonly pluginName: (serverId: string) => Promise<string>
}

export const previewScanLimit = 50

export const createSubscription = async (
  deps: PluginEventSubscriptionsDeps,
  request: CreatePluginEventSubscriptionRequest
): Promise<PluginEventSubscription> => {
  const type = await requireEventType(deps.types, request.plugin, request.event)
  const filter = requireFilter(request.filter, type)
  const record = await run(
    deps.db.createPluginEventSubscription({
      sessionId: request.sessionId,
      serverId: type.plugin,
      ...(request.accountId === undefined ? {} : { accountId: request.accountId }),
      eventName: type.name,
      arguments: request.arguments ?? {},
      ...(request.filter === undefined || request.filter.trim() === ""
        ? {}
        : { filter: request.filter.trim() }),
      explained: filter.explained,
      ...(request.note === undefined ? {} : { note: request.note }),
      once: request.once ?? false,
      createdBy: request.createdBy ?? "agent"
    })
  )
  return publicSubscription(record, type.pluginName)
}

export const listSubscriptions = async (
  deps: PluginEventSubscriptionsDeps,
  sessionId: string | undefined
): Promise<ReadonlyArray<PluginEventSubscription>> => {
  const records = await run(deps.db.listPluginEventSubscriptions(sessionId))
  return Promise.all(
    records.map(async (record) =>
      publicSubscription(record, await deps.pluginName(record.serverId))
    )
  )
}

export const previewSubscription = async (
  deps: PluginEventSubscriptionsDeps,
  request: PluginEventPreviewRequest
): Promise<PluginEventPreview> => {
  const type = await requireEventType(deps.types, request.plugin, request.event)
  const filter = requireFilter(request.filter, type)
  const recent = await run(deps.db.recentPluginEvents(type.plugin, type.name, previewScanLimit))
  const candidates = recent.filter(
    (event) => request.accountId === undefined || event.accountId === request.accountId
  )
  const matched = candidates.filter((event) =>
    filter.filter.matches(event.data, {
      eventId: event.sourceEventId,
      name: event.eventName,
      timestamp: event.occurredAt
    })
  )
  return {
    explained: filter.explained,
    scanned: candidates.length,
    matched: matched.map((event) => ({ eventId: event.id, occurredAt: event.occurredAt }))
  }
}

export const publicSubscription = (
  record: PluginEventSubscriptionRecord,
  pluginName: string
): PluginEventSubscription => ({
  id: record.id,
  sessionId: record.sessionId,
  plugin: record.serverId,
  pluginName,
  ...(record.accountId === undefined ? {} : { accountId: record.accountId }),
  event: record.eventName,
  arguments: record.arguments,
  ...(record.filter === undefined ? {} : { filter: record.filter }),
  explained: record.explained,
  ...(record.note === undefined ? {} : { note: record.note }),
  once: record.once,
  createdBy: record.createdBy,
  ...(record.pausedReason === undefined ? {} : { pausedReason: record.pausedReason }),
  createdAt: record.createdAt
})

const requireEventType = async (
  types: PluginEventTypes,
  plugin: string,
  event: string
): Promise<PluginEventType> => {
  const type = await types.find(plugin, event)
  if (type !== undefined) return type
  throw new HttpFailure(
    404,
    `No event "${event}" on plugin ${plugin}. List available events with events.topics.`
  )
}

const requireFilter = (
  expression: string | undefined,
  type: PluginEventType
): EventFilterAccepted => {
  const compiled = compileEventFilter(expression, type.payloadSchema)
  if (compiled.ok) return compiled
  throw new HttpFailure(400, `Invalid filter: ${compiled.error}`)
}
