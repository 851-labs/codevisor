import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const fixture = async () => {
  const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/plugin-events" }))
  const bot = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  const server = await run(
    db.saveMcpServer({
      name: "Grafana",
      transport: "stdio",
      command: "codevisor-plugin",
      args: ["codevisor.grafana"],
      enabled: true,
      authType: "none",
      connectionState: "connected",
      toolCount: 3,
      catalogId: "codevisor.grafana",
      catalogVersion: "1.0.0",
      capabilities: {
        tools: [{ name: "list_alerts", effects: "read" }],
        events: [{ name: "alert.firing" }],
        skills: [],
        panes: [],
        ingress: [{ name: "alerts" }]
      }
    })
  )
  return { db, bot, server }
}

const firing = (serverId: string, sourceEventId: string, accountId?: string) => ({
  serverId,
  ...(accountId === undefined ? {} : { accountId }),
  eventName: "alert.firing",
  sourceEventId,
  occurredAt: "2026-10-27T10:00:00.000Z",
  data: { labels: { host: "db-1" } }
})

describe("plugin event subscriptions", () => {
  it("stores, lists, pauses and deletes subscriptions per session", async () => {
    const { db, bot, server } = await fixture()
    const created = await run(
      db.createPluginEventSubscription({
        sessionId: bot.id.toUpperCase(),
        serverId: server.id,
        accountId: "acc-1",
        eventName: "alert.firing",
        arguments: { severity: "critical" },
        filter: 'labels.host == "db-1"',
        explained: 'labels.host is "db-1"',
        note: "Prod DB alerts",
        once: false,
        createdBy: "agent"
      })
    )
    expect(created.sessionId).toBe(bot.id)
    expect(await run(db.listPluginEventSubscriptions(bot.id))).toEqual([created])
    expect(await run(db.listPluginEventSubscriptions())).toEqual([created])

    await run(db.pausePluginEventSubscription(created.id, "200 events today"))
    expect((await run(db.getPluginEventSubscription(created.id)))?.pausedReason).toBe(
      "200 events today"
    )
    await run(db.pausePluginEventSubscription(created.id, undefined))
    expect((await run(db.getPluginEventSubscription(created.id)))?.pausedReason).toBeUndefined()

    expect(await run(db.deletePluginEventSubscription(created.id))).toBe(true)
    expect(await run(db.deletePluginEventSubscription(created.id))).toBe(false)
    expect(await run(db.getPluginEventSubscription(created.id))).toBeUndefined()
  })

  it("keeps the minimal shape for a user subscription without optional fields", async () => {
    const { db, bot, server } = await fixture()
    const created = await run(
      db.createPluginEventSubscription({
        sessionId: bot.id,
        serverId: server.id,
        eventName: "alert.firing",
        arguments: {},
        explained: "every event",
        once: true,
        createdBy: "user"
      })
    )
    expect(await run(db.getPluginEventSubscription(created.id))).toEqual(created)
    expect(created).not.toHaveProperty("accountId")
  })
})

describe("plugin events", () => {
  it("dedupes on the source event id per plugin, account and event name", async () => {
    const { db, server } = await fixture()
    const first = await run(db.recordPluginEvent(firing(server.id, "fp:1", "acc-1")))
    const again = await run(db.recordPluginEvent(firing(server.id, "fp:1", "acc-1")))
    const otherAccount = await run(db.recordPluginEvent(firing(server.id, "fp:1")))

    expect(first.duplicate).toBe(false)
    expect(again).toEqual({ event: first.event, duplicate: true })
    expect(otherAccount.duplicate).toBe(false)
    expect(otherAccount.event).not.toHaveProperty("accountId")
    expect(await run(db.getPluginEvent(first.event.id))).toEqual(first.event)
    expect(await run(db.getPluginEvent("missing"))).toBeUndefined()
    expect(
      (await run(db.recentPluginEvents(server.id, "alert.firing", 10))).map((event) => event.id)
    ).toEqual([otherAccount.event.id, first.event.id])
  })

  it("delivers each event once per subscription and remembers pending deliveries", async () => {
    const { db, bot, server } = await fixture()
    const subscription = await run(
      db.createPluginEventSubscription({
        sessionId: bot.id,
        serverId: server.id,
        eventName: "alert.firing",
        arguments: {},
        explained: "every event",
        once: false,
        createdBy: "agent"
      })
    )
    const { event } = await run(db.recordPluginEvent(firing(server.id, "fp:2")))

    expect(await run(db.addPluginEventDelivery(subscription.id, event.id))).toBe(true)
    expect(await run(db.addPluginEventDelivery(subscription.id, event.id))).toBe(false)
    expect(await run(db.pendingPluginEventDeliveries)).toEqual([
      { subscriptionId: subscription.id, event }
    ])
    const since = "2000-01-01T00:00:00.000Z"
    expect(await run(db.countPluginEventDeliveriesSince(subscription.id, since))).toBe(0)

    expect(await run(db.prunePluginEvents("2999-01-01T00:00:00.000Z"))).toBe(0)
    await run(db.markPluginEventDelivered(subscription.id, event.id))
    expect(await run(db.countPluginEventDeliveriesSince(subscription.id, since))).toBe(1)
    expect(await run(db.pendingPluginEventDeliveries)).toEqual([])
    expect(await run(db.prunePluginEvents("2999-01-01T00:00:00.000Z"))).toBe(1)
  })

  it("persists source cursors", async () => {
    const { db } = await fixture()
    expect(await run(db.pluginEventCursor("source"))).toBeUndefined()
    await run(db.savePluginEventCursor("source", "history-1"))
    expect(await run(db.pluginEventCursor("source"))).toBe("history-1")
    await run(db.savePluginEventCursor("source", undefined))
    expect(await run(db.pluginEventCursor("source"))).toBeUndefined()
  })
})

describe("plugin event edge cases", () => {
  it("dedupes events without an account and stores missing data as null", async () => {
    const { db, server } = await fixture()
    const occurrence = {
      serverId: server.id,
      eventName: "alert.firing",
      sourceEventId: "fp:9",
      occurredAt: "2026-10-27T10:00:00.000Z",
      data: undefined
    }
    const first = await run(db.recordPluginEvent(occurrence))
    expect(first.event.data).toBeUndefined()
    expect(await run(db.getPluginEvent(first.event.id))).toMatchObject({ data: null })
    expect((await run(db.recordPluginEvent(occurrence))).duplicate).toBe(true)
  })

  it("ignores a plugin capabilities column that no longer parses", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const saved = await run(
      db.saveMcpServer({
        name: "Odd",
        transport: "stdio",
        command: "odd",
        enabled: true,
        authType: "none",
        connectionState: "disconnected",
        toolCount: 0
      })
    )
    await run(db.close)
    const sqlite = new Database(filename)
    sqlite.prepare("update mcp_servers set capabilities = ? where id = ?").run("{broken", saved.id)
    sqlite.close()
    const reopened = await run(makeDatabase({ filename, serverId: "local" }))
    onTestFinished(() => run(reopened.close))
    expect(await run(reopened.getMcpServer(saved.id))).not.toHaveProperty("capabilities")
  })
})
