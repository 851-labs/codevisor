import { describe, expect, it } from "vitest"

import { createEventBuffer, type EventBuffer } from "./event-buffer.js"

const start = Date.parse("2026-10-27T12:00:00.000Z")

const appendPings = (buffer: EventBuffer, count: number, name = "test.ping"): void => {
  for (let index = 1; index <= count; index += 1) {
    buffer.append(
      {
        eventId: `${name}-${index}`,
        name,
        timestamp: new Date(start + index).toISOString(),
        data: {}
      },
      start + index * 1_000
    )
  }
}

const ids = (events: ReadonlyArray<{ eventId: string }>): Array<string> =>
  events.map((event) => event.eventId)

const request = (cursor: string | null, maxEvents = 10) => ({
  name: "test.ping",
  cursor,
  maxEvents
})

describe("createEventBuffer", () => {
  it("starts a null cursor at the current position without replaying", () => {
    const buffer = createEventBuffer("boot", 10)
    appendPings(buffer, 2)

    const replay = buffer.replay(request(null), start)

    expect(replay).toEqual({
      events: [],
      start: buffer.head(),
      cursor: buffer.head(),
      truncated: false,
      hasMore: false
    })
  })

  it("replays only events of the requested type after the cursor", () => {
    const buffer = createEventBuffer("boot", 10)
    const cursor = buffer.head()
    appendPings(buffer, 2)
    appendPings(buffer, 1, "test.counter")

    const replay = buffer.replay(request(cursor), start)

    expect(ids(replay.events)).toEqual(["test.ping-1", "test.ping-2"])
    expect(replay).toMatchObject({
      start: cursor,
      cursor: buffer.head(),
      truncated: false,
      hasMore: false
    })
    expect(buffer.replay(request(replay.cursor), start).events).toEqual([])
  })

  it("pages with an intermediate cursor when more events than maxEvents are pending", () => {
    const buffer = createEventBuffer("boot", 10)
    const cursor = buffer.head()
    appendPings(buffer, 3)

    const first = buffer.replay(request(cursor, 2), start)
    const second = buffer.replay(request(first.cursor, 2), start)

    expect(ids(first.events)).toEqual(["test.ping-1", "test.ping-2"])
    expect(first.hasMore).toBe(true)
    expect(first.cursor).toBe(first.events[1]?.cursor)
    expect(ids(second.events)).toEqual(["test.ping-3"])
    expect(second.hasMore).toBe(false)
  })

  it("marks a cursor that fell out of the buffer as truncated and resumes from the oldest event", () => {
    const buffer = createEventBuffer("boot", 2)
    const cursor = buffer.head()
    appendPings(buffer, 3)

    const replay = buffer.replay(request(cursor), start)

    expect(ids(replay.events)).toEqual(["test.ping-2", "test.ping-3"])
    expect(replay.truncated).toBe(true)
  })

  it("treats cursors from another boot, from the future or of another shape as truncated", () => {
    const buffer = createEventBuffer("boot", 10)
    const other = createEventBuffer("other", 10)
    appendPings(other, 1)
    appendPings(buffer, 1)
    const fresh = createEventBuffer("boot", 10)

    expect(buffer.replay(request(other.head()), start)).toMatchObject({
      truncated: true,
      events: [{ eventId: "test.ping-1" }]
    })
    expect(fresh.replay(request(buffer.head()), start)).toMatchObject({
      truncated: true,
      events: []
    })
    expect(buffer.replay(request("not a cursor"), start).truncated).toBe(true)
  })

  it("skips events older than maxAgeMs and reports the gap", () => {
    const buffer = createEventBuffer("boot", 10)
    const cursor = buffer.head()
    appendPings(buffer, 3)

    const replay = buffer.replay({ ...request(cursor), maxAgeMs: 1_500 }, start + 3_000)

    expect(ids(replay.events)).toEqual(["test.ping-2", "test.ping-3"])
    expect(replay.truncated).toBe(true)
  })

  it("lists the most recent events oldest first", () => {
    const buffer = createEventBuffer("boot", 10)
    appendPings(buffer, 3)

    expect(ids(buffer.recent(2))).toEqual(["test.ping-2", "test.ping-3"])
  })
})
