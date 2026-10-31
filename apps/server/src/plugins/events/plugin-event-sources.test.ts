import { describe, expect, it } from "vitest"

import { fixtureChanged } from "../../changes-test-support.js"
import { run, waitFor } from "../../test-support.js"
import { maxPollEvents } from "./plugin-event-source-modes.js"
import {
  eventList,
  eventsFixture,
  ping,
  pingPlugin,
  pingType,
  type EventsFixture,
  type RequestHandler
} from "./plugin-events-test-support.js"

const replies = (...results: ReadonlyArray<Record<string, unknown> | Error>): RequestHandler => {
  let call = 0
  return () => {
    const result = results[Math.min(call, results.length - 1)]!
    call += 1
    if (result instanceof Error) throw result
    return result
  }
}

const subscribeTo = async (
  fixture: EventsFixture,
  plugin: string,
  extra: Record<string, unknown> = {}
) => {
  const events = fixture.engine()
  const subscription = await events.subscribe({
    sessionId: fixture.session.id,
    plugin,
    event: "ping",
    ...extra
  })
  return { events, subscription }
}

const wakeThrough = async (fixture: EventsFixture, count: number): Promise<void> => {
  for (let index = 1; index <= count; index += 1) (await fixture.clock.nextSleep(index)).wake()
}

describe("polling plugin events", () => {
  it("polls from the saved cursor, keeps it through replies without one, and paces itself by hasMore and nextPollMs", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture, "Pinger", {
      "events/poll": replies(
        {
          events: [ping("e1"), { name: "ping" }, 7],
          cursor: "c1",
          truncated: true,
          hasMore: true
        },
        { events: [{ eventId: "e2", name: "ping" }], cursor: "c2", nextPollMs: 10 },
        { events: "none", cursor: 5, nextPollMs: 60_000 },
        { events: [] }
      )
    })
    await subscribeTo(fixture, pinger.id, { accountId: "work", arguments: { channel: "alerts" } })

    await wakeThrough(fixture, 3)
    await fixture.clock.nextSleep(4)

    const request = { name: "ping", arguments: { channel: "alerts" }, maxEvents: maxPollEvents }
    expect(fixture.fake.requestsOf("events/poll")).toEqual(
      [null, "c1", "c2", "c2"].map((cursor) => ({
        serverId: pinger.id,
        method: "events/poll",
        params: { ...request, cursor },
        accountId: "work"
      }))
    )
    expect(fixture.clock.delays()).toEqual([0, 1_000, 60_000, 30_000])
    expect(fixture.outbox.texts()).toEqual([
      expect.stringContaining('"message":"hello"'),
      expect.stringContaining("\n{}\n")
    ])
  })

  it("backs off after failures and starts over after a success", async () => {
    const fixture = await eventsFixture()
    const down = new Error("upstream down")
    const pinger = await pingPlugin(fixture, "Pinger", {
      "events/poll": replies(down, down, { events: [] }, down)
    })
    await subscribeTo(fixture, pinger.id)

    await wakeThrough(fixture, 3)
    await fixture.clock.nextSleep(4)

    expect(fixture.clock.delays()).toEqual([5_000, 10_000, 30_000, 5_000])
  })

  it("waits and retries while the plugin no longer offers the event", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    await subscribeTo(fixture, pinger.id)
    fixture.fake.add(pinger, { "events/list": eventList(), "events/poll": () => ({ events: [] }) })
    fixture.fake.reconnected(pinger.id)

    await fixture.clock.nextSleep(1)

    expect(fixture.clock.delays()).toEqual([5_000])
    expect(fixture.fake.requestsOf("events/poll")).toEqual([])
  })
})

const webhookPlugin = (fixture: EventsFixture) =>
  pingPlugin(fixture, "Hooks", { "events/list": eventList(pingType({ delivery: ["webhook"] })) })

describe("webhook-only plugin events", () => {
  it("retries when nothing on this Mac can receive the webhook", async () => {
    const fixture = await eventsFixture()
    const hooks = await webhookPlugin(fixture)
    await subscribeTo(fixture, hooks.id)

    await fixture.clock.nextSleep(1)

    expect(fixture.clock.delays()).toEqual([5_000])
  })

  it("hands the source to the webhook runner", async () => {
    const fixture = await eventsFixture()
    const hooks = await webhookPlugin(fixture)
    const runs: Array<{ readonly source: unknown; readonly delivery: unknown }> = []
    const events = fixture.engine({
      webhooks: () => ({
        run: async (source, type) => {
          runs.push({ source, delivery: type.delivery })
        }
      })
    })

    await events.subscribe({ sessionId: fixture.session.id, plugin: hooks.id, event: "ping" })
    await fixture.clock.nextSleep(1)

    expect(runs).toEqual([
      { source: { serverId: hooks.id, eventName: "ping", arguments: {} }, delivery: ["webhook"] }
    ])
    expect(fixture.clock.delays()).toEqual([0])
  })
})

const streamingPlugin = (fixture: EventsFixture) =>
  pingPlugin(fixture, "Streamer", {
    "events/list": eventList(pingType({ delivery: ["push", "poll"] }))
  })

describe("streaming plugin events", () => {
  it("ingests streamed events, saves every cursor it's sent and reconnects from the last one", async () => {
    const fixture = await eventsFixture()
    const streamer = await streamingPlugin(fixture)
    await subscribeTo(fixture, streamer.id, { accountId: "work" })
    await waitFor(() => fixture.fake.streams.length === 1)
    const stream = fixture.fake.streams[0]!

    stream.send("notifications/events/active", { cursor: "a1", truncated: false })
    stream.send("notifications/events/event", { ...ping("e1"), cursor: "a2" })
    stream.send("notifications/events/heartbeat", { cursor: "a3" })
    stream.send("notifications/events/heartbeat", { cursor: null })
    stream.send("notifications/events/error", { cursor: "ignored" })
    stream.end()
    await wakeThrough(fixture, 1)
    await waitFor(() => fixture.fake.streams.length === 2)

    expect(fixture.fake.streams.map((opened) => [opened.params, opened.accountId])).toEqual([
      [{ name: "ping", arguments: {}, cursor: null }, "work"],
      [{ name: "ping", arguments: {}, cursor: "a3" }, "work"]
    ])
    expect(fixture.clock.delays()).toEqual([1_000])
    expect(fixture.outbox.delivered).toHaveLength(1)
  })

  it("opens an account's stream with its ingress details and no extra details without an account", async () => {
    const fixture = await eventsFixture()
    const streamer = await streamingPlugin(fixture)
    const ingressMeta = {
      "dev.codevisor/ingress": { ingress: [{ name: "push", url: "https://in/i/1" }] }
    }
    const events = fixture.engine({
      ingress: {
        refresh: async () => undefined,
        urls: async () => [],
        meta: async (_serverId, accountId) => (accountId === "work" ? ingressMeta : {}),
        forget: async () => undefined,
        deliver: async () => undefined
      }
    })
    const request = { sessionId: fixture.session.id, plugin: streamer.id, event: "ping" }

    await events.subscribe({ ...request, accountId: "work" })
    await events.subscribe({ ...request, accountId: "home" })
    await events.subscribe({ ...request, arguments: { anyone: true } })
    await waitFor(() => fixture.fake.streams.length === 3)

    const opened = Object.fromEntries(
      fixture.fake.streams.map((stream) => [stream.accountId ?? "none", stream.params])
    )
    expect(opened).toEqual({
      work: { name: "ping", arguments: {}, cursor: null, _meta: ingressMeta },
      home: { name: "ping", arguments: {}, cursor: null },
      none: { name: "ping", arguments: { anyone: true }, cursor: null }
    })
  })

  it("shares one stream between subscriptions and closes it when the last one goes", async () => {
    const fixture = await eventsFixture()
    const streamer = await streamingPlugin(fixture)
    const refreshed: Array<number> = []
    const events = fixture.engine({
      ingress: {
        refresh: async (sources) => {
          refreshed.push(sources.length)
          fixtureChanged()
        },
        urls: async () => [],
        meta: async () => ({}),
        forget: async () => undefined,
        deliver: async () => undefined
      }
    })
    const request = { sessionId: fixture.session.id, plugin: streamer.id, event: "ping" }
    const first = await events.subscribe(request)
    const second = await events.subscribe(request)
    await waitFor(() => refreshed.length === 2 && fixture.fake.streams.length === 1)

    await events.unsubscribe(first.id)
    await waitFor(() => refreshed.length === 3)
    const whileShared = fixture.fake.streams[0]!.signal.aborted
    await events.unsubscribe(second.id)
    await waitFor(() => refreshed.length === 4)

    expect(whileShared).toBe(false)
    expect(fixture.fake.streams[0]!.signal.aborted).toBe(true)
    expect(fixture.fake.streams).toHaveLength(1)
    expect(refreshed).toEqual([1, 1, 1, 0])
    expect(events.activeSources()).toEqual([])
  })

  it("shares a source between subscriptions whose arguments differ only in key order", async () => {
    const fixture = await eventsFixture()
    const streamer = await streamingPlugin(fixture)
    const events = fixture.engine()
    const request = { sessionId: fixture.session.id, plugin: streamer.id, event: "ping" }

    await events.subscribe({
      ...request,
      arguments: { labels: [{ team: "web", env: "prod" }], folder: "alerts" }
    })
    await events.subscribe({
      ...request,
      arguments: { folder: "alerts", labels: [{ env: "prod", team: "web" }] }
    })
    await waitFor(() => fixture.fake.streams.length === 1)

    expect(events.activeSources()).toEqual([
      {
        serverId: streamer.id,
        eventName: "ping",
        arguments: { labels: [{ team: "web", env: "prod" }], folder: "alerts" }
      }
    ])
  })

  it("keeps a stream going after a delivery fails and retries the failed event with the next one", async () => {
    const fixture = await eventsFixture()
    const streamer = await streamingPlugin(fixture)
    await subscribeTo(fixture, streamer.id)
    await waitFor(() => fixture.fake.streams.length === 1)
    fixture.outbox.failNext()

    fixture.fake.streams[0]!.send("notifications/events/event", { ...ping("e1"), cursor: "a1" })
    fixture.fake.streams[0]!.send("notifications/events/event", { ...ping("e2"), cursor: "a2" })
    fixture.fake.streams[0]!.end()
    await fixture.clock.nextSleep(1)

    const delivered = await run(fixture.db.recentPluginEvents(streamer.id, "ping", 10))
    expect(fixture.outbox.delivered.map((entry) => entry.event.message.text)).toEqual(
      ["e1", "e2"].map((sourceEventId) =>
        expect.stringContaining(
          delivered.find((event) => event.sourceEventId === sourceEventId)!.id
        )
      )
    )
  })

  it("keeps subscribing while the cloud inbox can't be updated", async () => {
    const fixture = await eventsFixture()
    const streamer = await streamingPlugin(fixture)
    const events = fixture.engine({
      ingress: {
        refresh: () => Promise.reject(new Error("cloud unreachable")),
        urls: async () => [],
        meta: async () => ({}),
        forget: async () => undefined,
        deliver: async () => undefined
      }
    })

    await events.subscribe({ sessionId: fixture.session.id, plugin: streamer.id, event: "ping" })
    await waitFor(() => fixture.fake.streams.length === 1)

    expect(events.activeSources()).toHaveLength(1)
  })

  it("stops every source when closed", async () => {
    const fixture = await eventsFixture()
    const streamer = await streamingPlugin(fixture)
    const pinger = await pingPlugin(fixture, "Pinger", { "events/poll": () => ({ events: [] }) })
    const { events } = await subscribeTo(fixture, streamer.id)
    await events.subscribe({ sessionId: fixture.session.id, plugin: pinger.id, event: "ping" })
    await waitFor(() => fixture.fake.streams.length === 1)
    const sleeping = await fixture.clock.nextSleep(1)

    events.close()

    expect([fixture.fake.streams[0]!.signal.aborted, sleeping.signal.aborted]).toEqual([true, true])
    expect(events.activeSources()).toEqual([])
  })
})
