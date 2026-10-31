import { isRecord } from "../../unknown-values.js"
import type { EventConnection } from "./plugin-event-connections.js"
import type { EventOccurrence } from "./plugin-event-ingest.js"
import type { EventSource } from "./plugin-event-source-key.js"

export interface SourceRun {
  readonly source: EventSource
  readonly signal: AbortSignal
  readonly connection: EventConnection
  readonly meta: () => Promise<Record<string, unknown>>
  readonly cursor: () => Promise<string | undefined>
  readonly saveCursor: (cursor: string) => Promise<void>
  readonly ingest: (occurrences: ReadonlyArray<EventOccurrence>) => Promise<number>
}

export const minPollMs = 1_000
export const defaultPollMs = 30_000
export const maxPollEvents = 50

export const pollOnce = async (sourceRun: SourceRun): Promise<number> => {
  const result = await sourceRun.connection.request(
    "events/poll",
    {
      name: sourceRun.source.eventName,
      arguments: sourceRun.source.arguments,
      cursor: (await sourceRun.cursor()) ?? null,
      maxEvents: maxPollEvents
    },
    requestOptions(sourceRun)
  )
  await sourceRun.ingest(occurrencesOf(result.events))
  await saveReplyCursor(sourceRun, result.cursor)
  return nextPollDelay(result)
}

export const streamUntilClosed = async (sourceRun: SourceRun): Promise<void> => {
  let work = Promise.resolve()
  const enqueue = (step: () => Promise<unknown>): void => {
    work = work.then(step).then(
      () => undefined,
      () => undefined
    )
  }
  await sourceRun.connection.openStream(
    "events/stream",
    {
      name: sourceRun.source.eventName,
      arguments: sourceRun.source.arguments,
      cursor: (await sourceRun.cursor()) ?? null,
      ...streamMeta(await sourceRun.meta())
    },
    {
      ...requestOptions(sourceRun),
      signal: sourceRun.signal,
      onNotification: (method, params) => enqueue(() => onStreamMessage(sourceRun, method, params))
    }
  )
  await work
}

const onStreamMessage = async (
  sourceRun: SourceRun,
  method: string,
  params: Record<string, unknown>
): Promise<void> => {
  if (method === "notifications/events/event") await sourceRun.ingest(occurrencesOf([params]))
  if (carriesCursor(method)) await saveReplyCursor(sourceRun, params.cursor)
}

const streamMeta = (meta: Record<string, unknown>): { _meta?: Record<string, unknown> } =>
  Object.keys(meta).length === 0 ? {} : { _meta: meta }

const carriesCursor = (method: string): boolean =>
  method === "notifications/events/event" ||
  method === "notifications/events/active" ||
  method === "notifications/events/heartbeat"

const requestOptions = (sourceRun: SourceRun) => ({
  signal: sourceRun.signal,
  ...(sourceRun.source.accountId === undefined ? {} : { accountId: sourceRun.source.accountId })
})

export const occurrencesOf = (value: unknown): ReadonlyArray<EventOccurrence> =>
  Array.isArray(value) ? value.flatMap(occurrenceOf) : []

const occurrenceOf = (value: unknown): ReadonlyArray<EventOccurrence> => {
  if (!isRecord(value)) return []
  const raw = value
  if (typeof raw.eventId !== "string" || typeof raw.name !== "string") return []
  return [
    {
      eventId: raw.eventId,
      name: raw.name,
      timestamp: typeof raw.timestamp === "string" ? raw.timestamp : new Date().toISOString(),
      data: raw.data ?? {}
    }
  ]
}

const saveReplyCursor = async (sourceRun: SourceRun, cursor: unknown): Promise<void> => {
  if (typeof cursor !== "string") return
  await sourceRun.saveCursor(cursor)
}

const nextPollDelay = (result: Record<string, unknown>): number => {
  if (result.hasMore === true) return 0
  const suggested = typeof result.nextPollMs === "number" ? result.nextPollMs : defaultPollMs
  return Math.max(minPollMs, suggested)
}
