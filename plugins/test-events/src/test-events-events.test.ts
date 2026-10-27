import { heartbeatIntervalMs } from "@codevisor/plugin-kit"
import {
  anyResult,
  type ConnectedClient,
  connectClient,
  manualClock,
  openStream
} from "@codevisor/plugin-kit/test-support"
import { afterEach, describe, expect, it } from "vitest"
import { z } from "zod"

import { createTestEventsServer, testEventsDefaults } from "./test-events-server.js"

const connections: Array<ConnectedClient> = []

const emittedCursor = z.object({ event: z.object({ cursor: z.string() }) })

const connect = async (options: Parameters<typeof createTestEventsServer>[0] = {}) => {
  const clock = manualClock()
  const connected = await connectClient(
    createTestEventsServer({ clock, bootId: "boot", ...options })
  )
  connections.push(connected)
  return { ...connected, clock }
}

const emit = (connected: ConnectedClient, args: Record<string, unknown>) =>
  connected.client.callTool({ name: "emit", arguments: args })

const poll = (connected: ConnectedClient, params: Record<string, unknown>) =>
  connected.client.request({ method: "events/poll", params }, anyResult)

describe("test-events events", () => {
  afterEach(async () => {
    await Promise.all(connections.splice(0).map((connected) => connected.client.close()))
  })

  it("declares the events, skills, ui and panes extensions", async () => {
    const { client } = await connect()

    expect(client.getServerCapabilities()?.extensions).toEqual({
      "io.modelcontextprotocol/events": { listChanged: false },
      "io.modelcontextprotocol/skills": {},
      "io.modelcontextprotocol/ui": {},
      "dev.codevisor/panes": {
        panes: [
          { type: "events", title: "Test events", resourceUri: "ui://test-events/events.html" }
        ]
      }
    })
  })

  it("lists both event types with poll and push delivery", async () => {
    const { client } = await connect()

    const listed = await client.request({ method: "events/list", params: {} }, anyResult)

    expect(listed.resultType).toBe("complete")
    expect(listed.events).toMatchObject([
      {
        name: "test.ping",
        delivery: ["poll", "push"],
        payloadSchema: { required: ["message", "level", "tags", "count"] }
      },
      { name: "test.counter", delivery: ["poll", "push"] }
    ])
  })

  it("polls emitted events from a cursor with defaults filled in", async () => {
    const connected = await connect()
    const bootstrap = await poll(connected, { name: "test.ping", arguments: {}, cursor: null })
    await emit(connected, {
      name: "test.ping",
      data: { level: "warn", tags: ["db"] },
      eventId: "upstream-1"
    })

    const polled = await poll(connected, {
      name: "test.ping",
      arguments: {},
      cursor: bootstrap.cursor
    })

    expect(bootstrap).toMatchObject({
      resultType: "complete",
      events: [],
      truncated: false,
      hasMore: false
    })
    expect(polled).toMatchObject({
      truncated: false,
      hasMore: false,
      nextPollMs: testEventsDefaults.nextPollMs
    })
    expect(polled.events).toEqual([
      {
        eventId: "upstream-1",
        name: "test.ping",
        timestamp: "2026-10-27T12:00:00.000Z",
        data: { message: "ping", level: "warn", tags: ["db"], count: 1 },
        cursor: polled.cursor
      }
    ])
  })

  it("caps a poll at maxEvents and reports hasMore", async () => {
    const connected = await connect()
    const bootstrap = await poll(connected, { name: "test.counter", cursor: null })
    await emit(connected, { name: "test.counter" })
    await emit(connected, { name: "test.counter" })

    const first = await poll(connected, {
      name: "test.counter",
      cursor: bootstrap.cursor,
      maxEvents: 1
    })
    const second = await poll(connected, {
      name: "test.counter",
      cursor: first.cursor,
      maxEvents: 1
    })

    expect(first).toMatchObject({ hasMore: true, events: [{ data: { value: 1 } }] })
    expect(second).toMatchObject({ hasMore: false, events: [{ data: { value: 2 } }] })
  })

  it("reports truncated when the poll cursor fell out of the buffer", async () => {
    const connected = await connect({ capacity: 1 })
    const bootstrap = await poll(connected, { name: "test.ping", cursor: null })
    await emit(connected, { name: "test.ping", eventId: "lost" })
    await emit(connected, { name: "test.ping", eventId: "kept" })

    const polled = await poll(connected, { name: "test.ping", cursor: bootstrap.cursor })

    expect(polled).toMatchObject({ truncated: true, events: [{ eventId: "kept" }] })
  })

  it("rejects polls and streams for unknown event types", async () => {
    const connected = await connect()
    const notFound = {
      code: -32023,
      message: "MCP error -32023: Unknown event type: test.missing",
      data: { kind: "event" }
    }

    await expect(poll(connected, { name: "test.missing", cursor: null })).rejects.toMatchObject(
      notFound
    )
    await expect(
      connected.client.request(
        { method: "events/stream", params: { name: "test.missing" } },
        anyResult
      )
    ).rejects.toMatchObject(notFound)
  })

  it("confirms a stream, then delivers matching events tagged with its subscription id", async () => {
    const connected = await connect()
    const pings = await openStream(connected, { name: "test.ping", arguments: {}, cursor: null })
    const counters = await openStream(connected, { name: "test.counter", cursor: null })
    await emit(connected, { name: "test.ping", eventId: "p-1" })

    const delivered = await connected.inbox.next("notifications/events/event", pings.subscriptionId)

    expect(pings.active.params).toMatchObject({ truncated: false, cursor: expect.any(String) })
    expect(delivered.params).toMatchObject({
      eventId: "p-1",
      name: "test.ping",
      cursor: expect.any(String)
    })
    expect(
      connected.inbox.forSubscription(counters.subscriptionId).map((message) => message.method)
    ).toEqual(["notifications/events/active"])
  })

  it("replays buffered events after the stream cursor before live ones", async () => {
    const connected = await connect()
    const bootstrap = await poll(connected, { name: "test.ping", cursor: null })
    await emit(connected, { name: "test.ping", eventId: "missed" })

    const stream = await openStream(connected, { name: "test.ping", cursor: bootstrap.cursor })
    const replayed = await connected.inbox.next("notifications/events/event", stream.subscriptionId)

    expect(stream.active.params).toMatchObject({ cursor: bootstrap.cursor, truncated: false })
    expect(replayed.params).toMatchObject({ eventId: "missed" })
  })

  it("sends heartbeats carrying the current cursor", async () => {
    const connected = await connect()
    const stream = await openStream(connected, { name: "test.ping", cursor: null })
    const emitted = await emit(connected, { name: "test.counter" })

    connected.clock.advance(heartbeatIntervalMs)
    const heartbeat = await connected.inbox.next(
      "notifications/events/heartbeat",
      stream.subscriptionId
    )

    expect(heartbeat.params?.["cursor"]).toBe(
      emittedCursor.parse(emitted.structuredContent).event.cursor
    )
  })

  it("stops delivering to a stream after notifications/cancelled", async () => {
    const connected = await connect()
    const cancel = new AbortController()
    const cancelled = await openStream(
      connected,
      { name: "test.ping", cursor: null },
      cancel.signal
    )
    const open = await openStream(connected, { name: "test.ping", cursor: null })

    cancel.abort()
    await expect(cancelled.closed).rejects.toThrow()
    await emit(connected, { name: "test.ping", eventId: "after-cancel" })
    await connected.inbox.next("notifications/events/event", open.subscriptionId)
    connected.clock.advance(heartbeatIntervalMs)
    await connected.inbox.next("notifications/events/heartbeat", open.subscriptionId)

    expect(
      connected.inbox.forSubscription(cancelled.subscriptionId).map((message) => message.method)
    ).toEqual(["notifications/events/active"])
    expect(connected.clock.timers()).toBe(1)
  })

  it("ends open streams and timers when the connection closes", async () => {
    const connected = await connect({ intervalMs: 60_000 })
    await openStream(connected, { name: "test.ping", cursor: null })
    expect(connected.clock.timers()).toBe(2)

    await connected.client.close()

    expect(connected.clock.timers()).toBe(0)
  })
})
