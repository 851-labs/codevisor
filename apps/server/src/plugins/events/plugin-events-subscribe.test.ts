import { describe, expect, it } from "vitest"

import {
  capabilitiesWith,
  eventList,
  eventsFixture,
  ping,
  pingPlugin,
  pingType,
  savePluginRow
} from "./plugin-events-test-support.js"

describe("plugin event types", () => {
  it("lists the events of every enabled plugin across pages and narrows them by query", async () => {
    const fixture = await eventsFixture()
    const pinger = await savePluginRow(fixture.db, "Pinger")
    const disabled = await savePluginRow(fixture.db, "Disabled", { enabled: false })
    const toolsOnly = await savePluginRow(fixture.db, "Tools", {
      capabilities: capabilitiesWith({ events: [] })
    })
    fixture.fake.add(pinger, {
      "events/list": (params) =>
        params.cursor === "page-2"
          ? { events: [{ name: "pong", delivery: ["push", "carrier-pigeon"] }] }
          : { events: [pingType(), "garbage", { description: "nameless" }], nextCursor: "page-2" }
    })
    fixture.fake.add(disabled, { "events/list": eventList(pingType()) })
    fixture.fake.add(toolsOnly, { "events/list": eventList(pingType()) })
    const events = fixture.engine()

    const all = await events.types()
    const pongs = await events.types(" PONG ")
    const described = await events.types("a ping")

    expect(all).toEqual([
      {
        plugin: pinger.id,
        pluginName: "Pinger",
        name: "ping",
        description: "A ping",
        delivery: ["poll"],
        inputSchema: { type: "object" },
        payloadSchema: pingType().payloadSchema
      },
      { plugin: pinger.id, pluginName: "Pinger", name: "pong", delivery: ["push"] }
    ])
    expect(pongs.map((type) => type.name)).toEqual(["pong"])
    expect(described.map((type) => type.name)).toEqual(["ping"])
    expect(fixture.fake.requestsOf("events/list")).toEqual([
      { serverId: pinger.id, method: "events/list", params: {} },
      { serverId: pinger.id, method: "events/list", params: { cursor: "page-2" } }
    ])
  })

  it("reads malformed event listings as no events and no delivery modes", async () => {
    const fixture = await eventsFixture()
    await pingPlugin(fixture, "Garbled", { "events/list": () => ({ events: "none" }) })
    await pingPlugin(fixture, "Bare", { "events/list": eventList({ name: "bare" }) })
    const events = fixture.engine()

    const types = await events.types()

    expect(types.map((type) => [type.pluginName, type.name, type.delivery])).toEqual([
      ["Bare", "bare", []]
    ])
  })

  it("asks a plugin for its events again only after it reconnects", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()

    await events.types()
    await events.types()
    const beforeReconnect = fixture.fake.requestsOf("events/list").length
    fixture.fake.reconnected(pinger.id)
    await events.types()

    expect(beforeReconnect).toBe(1)
    expect(fixture.fake.requestsOf("events/list")).toHaveLength(2)
  })

  it("retries discovery after a plugin fails to list its events", async () => {
    const fixture = await eventsFixture()
    let failing = true
    await pingPlugin(fixture, "Pinger", {
      "events/list": () => {
        if (!failing) return { events: [pingType()] }
        failing = false
        throw new Error("not ready")
      }
    })
    const events = fixture.engine()

    const whileFailing = await events.types()
    const recovered = await events.types()

    expect(whileFailing).toEqual([])
    expect(recovered.map((type) => type.name)).toEqual(["ping"])
  })
})

describe("subscribing to plugin events", () => {
  it("type-checks the filter, reads it back in plain English and lists the subscription", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()

    const created = await events.subscribe({
      sessionId: fixture.session.id,
      plugin: "pinger",
      event: "ping",
      filter: '  count >= 2 && level == "warn"  ',
      note: "Warn pings"
    })

    expect(created).toEqual({
      id: expect.any(String),
      sessionId: fixture.session.id,
      plugin: pinger.id,
      pluginName: "Pinger",
      event: "ping",
      arguments: {},
      filter: 'count >= 2 && level == "warn"',
      explained: 'count is at least 2 and level is "warn"',
      note: "Warn pings",
      once: false,
      createdBy: "agent",
      createdAt: expect.any(String)
    })
    expect(await events.subscriptions(fixture.session.id)).toEqual([created])
  })

  it("refuses a filter that doesn't type-check against the payload schema", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()

    const subscribing = events.subscribe({
      sessionId: fixture.session.id,
      plugin: pinger.id,
      event: "ping",
      filter: "level == 3"
    })

    await expect(subscribing).rejects.toMatchObject({
      status: 400,
      message: 'Invalid filter: no such overload: string == int in "level == 3".'
    })
    expect(await events.subscriptions()).toEqual([])
  })

  it("points at events.topics when the plugin doesn't offer the event", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine({ resolveAccount: async () => "account-1" })

    const subscribing = events.subscribe({
      sessionId: fixture.session.id,
      plugin: pinger.id,
      event: "pong"
    })

    await expect(subscribing).rejects.toMatchObject({
      status: 404,
      message: `No event "pong" on plugin ${pinger.id}. List available events with events.topics.`
    })
  })

  it("treats a blank filter as every event and keeps the caller's options", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()

    const created = await events.subscribe({
      sessionId: fixture.session.id,
      plugin: pinger.id,
      event: "ping",
      filter: "   ",
      arguments: { channel: "alerts" },
      once: true,
      createdBy: "user"
    })

    expect(created).toMatchObject({ explained: "every event", once: true, createdBy: "user" })
    expect(created).not.toHaveProperty("filter")
    expect(created.arguments).toEqual({ channel: "alerts" })
  })

  it("subscribes through the plugin's default account unless one is named", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const accounts = new Map([["Work", "account-work"]])
    const events = fixture.engine({
      resolveAccount: async (_serverId, requested) =>
        requested === undefined ? "account-default" : accounts.get(requested)
    })
    const request = { sessionId: fixture.session.id, plugin: pinger.id, event: "ping" }

    const byDefault = await events.subscribe(request)
    const named = await events.subscribe({ ...request, accountId: "Work" })
    const unknown = await events.subscribe({ ...request, accountId: "Home" })

    expect([byDefault.accountId, named.accountId, unknown.accountId]).toEqual([
      "account-default",
      "account-work",
      "Home"
    ])
  })

  it("names subscriptions by plugin id once the plugin is gone", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()
    await events.subscribe({ sessionId: fixture.session.id, plugin: pinger.id, event: "ping" })

    fixture.fake.remove(pinger.id)

    expect((await events.subscriptions()).map((subscription) => subscription.pluginName)).toEqual([
      pinger.id
    ])
  })

  it("removes a subscription once", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()
    const created = await events.subscribe({
      sessionId: fixture.session.id,
      plugin: pinger.id,
      event: "ping"
    })

    const removed = await events.unsubscribe(created.id)
    const again = await events.unsubscribe(created.id)

    expect([removed, again]).toEqual([true, false])
    expect(await events.subscriptions(fixture.session.id)).toEqual([])
  })
})

describe("previewing and reading plugin events", () => {
  it("matches a filter against the plugin's recent events, per account when asked", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()
    const source = (accountId: string) => ({
      serverId: pinger.id,
      accountId,
      eventName: "ping",
      arguments: {}
    })
    await events.ingest(source("work"), [ping("e1"), ping("e2", { level: "warn" })])
    await events.ingest(source("home"), [ping("e3", { level: "warn" })])
    const request = { plugin: pinger.id, event: "ping", filter: 'level == "warn"' }

    const work = await events.preview({ ...request, accountId: "work" })
    const everyone = await events.preview(request)

    expect(work.explained).toBe('level is "warn"')
    expect([work.scanned, work.matched.length]).toEqual([2, 1])
    expect([everyone.scanned, everyone.matched.length]).toEqual([3, 2])
    expect(await events.event(work.matched[0]!.eventId)).toEqual({
      id: work.matched[0]!.eventId,
      plugin: pinger.id,
      accountId: "work",
      event: "ping",
      sourceEventId: "e2",
      occurredAt: "2026-10-27T09:00:00.000Z",
      receivedAt: expect.any(String),
      data: { message: "hello", level: "warn", count: 1 }
    })
  })

  it("refuses to preview a filter that doesn't type-check", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()

    const previewing = events.preview({ plugin: pinger.id, event: "ping", filter: "nope == 1" })

    await expect(previewing).rejects.toMatchObject({ status: 400 })
  })

  it("reads an event without an account and reports unknown events as missing", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const events = fixture.engine()
    await events.ingest({ serverId: pinger.id, eventName: "ping", arguments: {} }, [ping("e1")])
    const { matched } = await events.preview({ plugin: pinger.id, event: "ping" })

    const stored = await events.event(matched[0]!.eventId)

    expect(stored).not.toHaveProperty("accountId")
    expect(stored?.sourceEventId).toBe("e1")
    expect(await events.event("missing")).toBeUndefined()
  })
})
