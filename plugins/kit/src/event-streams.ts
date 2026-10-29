import type { RequestHandlerExtra } from "@modelcontextprotocol/sdk/shared/protocol.js"
import type { Notification, Request, RequestId } from "@modelcontextprotocol/sdk/types.js"

import type { Clock } from "./clock.js"
import { subscriptionIdMeta } from "./plugin-protocol.js"

export interface EventOccurrence {
  eventId: string
  name: string
  timestamp: string
  data: Record<string, unknown>
  cursor: string | null
}

export interface StreamPosition {
  cursor: string | null
  truncated: boolean
}

export interface StreamSubscription {
  name: string
  accountId: string | undefined
}

export interface StreamOpening extends StreamSubscription {
  position: StreamPosition
  backlog: ReadonlyArray<EventOccurrence>
  lifetimeMs?: number
}

export interface StreamClosed {
  [key: string]: unknown
  resultType: "complete"
  _meta: Record<string, RequestId>
}

export type StreamExtra = RequestHandlerExtra<Request, Notification>

export interface EventStreams {
  open(opening: StreamOpening, extra: StreamExtra): Promise<StreamClosed>
  publish(occurrence: EventOccurrence, matches: (stream: StreamSubscription) => boolean): number
  count(): number
}

export interface EventStreamsOptions {
  clock: Clock
  heartbeatCursor: (stream: StreamSubscription) => string | null
}

export const heartbeatIntervalMs = 15_000

export const createEventStreams = (options: EventStreamsOptions): EventStreams => {
  const live = new Set<LiveStream>()

  return {
    open: (opening, extra) => openStream(live, options, opening, extra),
    publish: (occurrence, matches) => publishTo(live, occurrence, matches),
    count: () => live.size
  }
}

interface LiveStream extends StreamSubscription {
  send(method: string, params: Record<string, unknown>): void
  close(): void
}

const openStream = (
  live: Set<LiveStream>,
  options: EventStreamsOptions,
  opening: StreamOpening,
  extra: StreamExtra
): Promise<StreamClosed> =>
  new Promise((resolve) => {
    const closed = streamClosed(extra.requestId)
    if (extra.signal.aborted) {
      resolve(closed)
      return
    }

    const stream = liveStream(opening, extra, options, () => {
      live.delete(stream)
      resolve(closed)
    })
    live.add(stream)
    extra.signal.addEventListener("abort", () => stream.close(), { once: true })
    deliverOpening(stream, opening)
  })

const liveStream = (
  opening: StreamOpening,
  extra: StreamExtra,
  options: EventStreamsOptions,
  onClose: () => void
): LiveStream => {
  const timers: Array<() => void> = []
  const stream: LiveStream = {
    name: opening.name,
    accountId: opening.accountId,
    send: (method, params) => {
      extra.sendNotification(tagged(method, params, extra.requestId)).catch(() => stream.close())
    },
    close: () => {
      for (const stop of timers.splice(0)) stop()
      onClose()
    }
  }
  timers.push(
    options.clock.every(heartbeatIntervalMs, () =>
      stream.send("notifications/events/heartbeat", { cursor: options.heartbeatCursor(stream) })
    )
  )
  if (opening.lifetimeMs !== undefined)
    timers.push(options.clock.every(opening.lifetimeMs, () => stream.close()))
  return stream
}

const deliverOpening = (stream: LiveStream, opening: StreamOpening): void => {
  stream.send("notifications/events/active", { ...opening.position })
  for (const occurrence of opening.backlog)
    stream.send("notifications/events/event", { ...occurrence })
}

const publishTo = (
  live: Set<LiveStream>,
  occurrence: EventOccurrence,
  matches: (stream: StreamSubscription) => boolean
): number => {
  const targets = [...live].filter((stream) => matches(stream))
  for (const stream of targets) stream.send("notifications/events/event", { ...occurrence })
  return targets.length
}

const tagged = (
  method: string,
  params: Record<string, unknown>,
  requestId: RequestId
): Notification => ({
  method,
  params: { ...params, _meta: { [subscriptionIdMeta]: requestId } }
})

const streamClosed = (requestId: RequestId): StreamClosed => ({
  resultType: "complete",
  _meta: { [subscriptionIdMeta]: requestId }
})
