import type { PluginEventType } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { run } from "../../server-context.js"
import type { PluginEventConnections } from "./plugin-event-connections.js"
import type { PluginEventIngest } from "./plugin-event-ingest.js"
import { sourceKeyOf, sourceOf, type EventSource } from "./plugin-event-source-key.js"
import { pollOnce, streamUntilClosed, type SourceRun } from "./plugin-event-source-modes.js"
import type { PluginEventTypes } from "./plugin-event-types.js"

export interface EventTimers {
  readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>
}

export interface WebhookSources {
  readonly run: (source: EventSource, type: PluginEventType, signal: AbortSignal) => Promise<void>
}

export interface PluginEventSourcesDeps {
  readonly db: CodevisorDatabaseService
  readonly connections: PluginEventConnections
  readonly types: PluginEventTypes
  readonly ingest: PluginEventIngest
  readonly timers: EventTimers
  readonly webhooks?: WebhookSources
  readonly onSourcesChanged?: (sources: ReadonlyArray<EventSource>) => Promise<void>
  readonly streamMeta?: (source: EventSource) => Promise<Record<string, unknown>>
}

export interface PluginEventSources {
  readonly refresh: () => Promise<void>
  readonly active: () => ReadonlyArray<EventSource>
  readonly close: () => void
}

export const retryDelayMs = (failures: number): number =>
  Math.min(maxRetryMs, firstRetryMs * 2 ** Math.max(0, failures - 1))

export const makePluginEventSources = (deps: PluginEventSourcesDeps): PluginEventSources => {
  const running = new Map<string, RunningSource>()

  const start = (source: EventSource): void => {
    const controller = new AbortController()
    const key = sourceKeyOf(source)
    running.set(key, { source, controller })
    void runSource(deps, source, controller.signal)
  }

  const stop = (key: string): void => {
    running.get(key)?.controller.abort()
    running.delete(key)
  }

  return {
    refresh: async () => {
      const wanted = await desiredSources(deps.db)
      for (const key of running.keys()) if (!wanted.has(key)) stop(key)
      for (const [key, source] of wanted) if (!running.has(key)) start(source)
      await deps.onSourcesChanged?.([...wanted.values()])
    },
    active: () => [...running.values()].map((entry) => entry.source),
    close: () => {
      for (const key of running.keys()) stop(key)
    }
  }
}

interface RunningSource {
  readonly source: EventSource
  readonly controller: AbortController
}

const firstRetryMs = 5_000
const maxRetryMs = 5 * 60_000
const streamReconnectMs = 1_000

const desiredSources = async (
  db: CodevisorDatabaseService
): Promise<ReadonlyMap<string, EventSource>> => {
  const active = (await run(db.listPluginEventSubscriptions())).filter(
    (subscription) => subscription.pausedReason === undefined
  )
  return new Map(active.map((subscription) => [sourceKeyOf(subscription), sourceOf(subscription)]))
}

const runSource = async (
  deps: PluginEventSourcesDeps,
  source: EventSource,
  signal: AbortSignal
): Promise<void> => {
  let failures = 0
  while (!signal.aborted) {
    try {
      const delay = await runOnce(deps, source, signal)
      failures = 0
      await deps.timers.sleep(delay, signal)
    } catch {
      failures += 1
      await deps.timers.sleep(retryDelayMs(failures), signal).catch(() => undefined)
    }
  }
}

const runOnce = async (
  deps: PluginEventSourcesDeps,
  source: EventSource,
  signal: AbortSignal
): Promise<number> => {
  const type = await deps.types.find(source.serverId, source.eventName)
  if (type === undefined) throw new Error(`Event type is unavailable: ${source.eventName}`)

  const sourceRun = await sourceRunFor(deps, source, signal)
  if (type.delivery.includes("push")) return streamThenReconnect(sourceRun)
  if (type.delivery.includes("poll")) return pollOnce(sourceRun)
  if (type.delivery.includes("webhook") && deps.webhooks !== undefined) {
    await deps.webhooks.run(source, type, signal)
    return 0
  }
  throw new Error(`No supported delivery for ${source.eventName}`)
}

const streamThenReconnect = async (sourceRun: SourceRun): Promise<number> => {
  await streamUntilClosed(sourceRun)
  return streamReconnectMs
}

const sourceRunFor = async (
  deps: PluginEventSourcesDeps,
  source: EventSource,
  signal: AbortSignal
): Promise<SourceRun> => {
  const key = sourceKeyOf(source)
  return {
    source,
    signal,
    connection: await deps.connections.connection(source.serverId),
    meta: () => deps.streamMeta?.(source) ?? Promise.resolve({}),
    cursor: () => run(deps.db.pluginEventCursor(key)),
    saveCursor: (cursor) => run(deps.db.savePluginEventCursor(key, cursor)),
    ingest: (occurrences) => deps.ingest.ingest(source, occurrences)
  }
}
