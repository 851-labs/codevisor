import type { EventOccurrence } from "@codevisor/plugin-kit"

export type BufferedOccurrence = Omit<EventOccurrence, "cursor">

export interface ReplayRequest {
  name: string
  cursor?: string | null | undefined
  maxAgeMs?: number | undefined
  maxEvents: number
}

export interface Replay {
  events: ReadonlyArray<EventOccurrence>
  start: string
  cursor: string
  truncated: boolean
  hasMore: boolean
}

export interface EventBuffer {
  append(occurrence: BufferedOccurrence, at: number): EventOccurrence
  head(): string
  recent(limit: number): ReadonlyArray<EventOccurrence>
  replay(request: ReplayRequest, now: number): Replay
}

export const createEventBuffer = (bootId: string, capacity: number): EventBuffer => {
  const retained: Array<Entry> = []
  let sequence = 0
  const evictedThrough = (): number => sequence - retained.length
  const cursorAt = (position: number): string => encodeCursor(bootId, position)
  const occurrence = (entry: Entry): EventOccurrence => ({
    ...entry.occurrence,
    cursor: cursorAt(entry.sequence)
  })

  const startOf = (cursor: string): StartPoint => {
    const position = decodeCursor(cursor)
    if (position === undefined || !servable(position))
      return { after: evictedThrough(), truncated: true }

    return { after: position.sequence, truncated: false }
  }

  const servable = (position: CursorPosition): boolean =>
    position.bootId === bootId &&
    position.sequence >= evictedThrough() &&
    position.sequence <= sequence

  return {
    append: (event, at) => {
      sequence += 1
      const entry = { sequence, at, occurrence: event }
      retained.push(entry)
      if (retained.length > capacity) retained.shift()
      return occurrence(entry)
    },
    head: () => cursorAt(sequence),
    recent: (limit) => retained.slice(-limit).map(occurrence),
    replay: (request, now) => {
      if (request.cursor == null) return fromNow(cursorAt(sequence))

      const start = startOf(request.cursor)
      const pending = retained.filter(
        (entry) => entry.sequence > start.after && entry.occurrence.name === request.name
      )
      const fresh = pending.filter((entry) => withinAge(entry, request.maxAgeMs, now))
      const batch = fresh.slice(0, request.maxEvents)
      const nextUnread = fresh[batch.length]
      return {
        events: batch.map(occurrence),
        start: cursorAt(start.after),
        cursor: cursorAt(nextUnread === undefined ? sequence : nextUnread.sequence - 1),
        truncated: start.truncated || fresh.length < pending.length,
        hasMore: nextUnread !== undefined
      }
    }
  }
}

interface Entry {
  sequence: number
  at: number
  occurrence: BufferedOccurrence
}

interface StartPoint {
  after: number
  truncated: boolean
}

interface CursorPosition {
  bootId: string
  sequence: number
}

const fromNow = (cursor: string): Replay => ({
  events: [],
  start: cursor,
  cursor,
  truncated: false,
  hasMore: false
})

const withinAge = (entry: Entry, maxAgeMs: number | undefined, now: number): boolean =>
  maxAgeMs === undefined || entry.at >= now - maxAgeMs

const encodeCursor = (bootId: string, sequence: number): string =>
  Buffer.from(`${bootId}:${sequence}`, "utf8").toString("base64url")

const decodeCursor = (cursor: string): CursorPosition | undefined => {
  const decoded = Buffer.from(cursor, "base64url").toString("utf8")
  const match = cursorPattern.exec(decoded)
  if (match === null) return undefined

  return { bootId: String(match[1]), sequence: Number(match[2]) }
}

const cursorPattern = /^(.+):(\d+)$/
