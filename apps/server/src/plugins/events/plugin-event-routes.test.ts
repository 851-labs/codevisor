import {
  decode,
  PluginEventRecord,
  PluginEventSubscription,
  PluginEventSubscriptionsResponse,
  PluginEventType
} from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, waitFor } from "../../test-support.js"
import { makePluginAccountStore } from "../accounts/plugin-account-store.js"
import {
  createChat,
  installTestEvents,
  pluginEventPrompts,
  post,
  startPluginServer,
  startWithoutPlugins,
  testEventsId,
  watchStreams,
  type PluginServer
} from "../plugin-test-support.js"

const PreviewResponse = Schema.Struct({
  matched: Schema.Array(Schema.Struct({ eventId: Schema.String }))
})

const TypesResponse = Schema.Struct({ types: Schema.Array(PluginEventType) })

const emit = async (running: PluginServer, serverId: string, data: Record<string, unknown>) => {
  const connection = await running.mcp.pluginConnection(serverId)
  await connection.request("tools/call", { name: "emit", arguments: { name: "test.ping", data } })
}

const subscribe = async (running: PluginServer, body: Record<string, unknown>) =>
  post(running, "/v1/plugins/events/subscriptions", {
    plugin: "Test Events",
    event: "test.ping",
    ...body
  })

const pingsStored = async (running: PluginServer, serverId: string, count: number) =>
  waitFor(
    async () =>
      (await run(running.services.db.recentPluginEvents(serverId, "test.ping", 10))).length ===
      count
  )

const seedAccounts = async (running: PluginServer, labels: ReadonlyArray<string>) => {
  const store = makePluginAccountStore(running.services.db, "server-a")
  for (const [index, label] of labels.entries()) {
    await store.save({
      id: `account-${label.toLowerCase()}`,
      plugin: testEventsId,
      label,
      method: "fields",
      values: {},
      secretsSet: [],
      status: "ok",
      createdAt: `2026-10-27T09:00:0${index}.000Z`
    })
  }
}

describe("plugin event routes", () => {
  it("lists types, subscribes, previews, reads and removes over HTTP", async () => {
    const running = await startPluginServer()
    const streams = watchStreams(running)
    const plugin = await installTestEvents(running)
    const watcher = await createChat(running, "Watcher")
    const bystanderChat = await createChat(running, "Bystander")

    const types = await jsonRequest(running.server, "/v1/plugins/events/types?query=counter")
    const created = decode(PluginEventSubscription)(
      (await subscribe(running, { sessionId: watcher, filter: 'level == "warn"' })).body
    )
    await waitFor(() => streams.length > 0)
    await emit(running, plugin.id, { level: "warn" })
    await pingsStored(running, plugin.id, 1)
    const preview = await post(running, "/v1/plugins/events/preview", {
      plugin: plugin.id,
      event: "test.ping",
      filter: 'level == "warn"'
    })
    const unfiltered = await post(running, "/v1/plugins/events/preview", {
      plugin: plugin.id,
      event: "test.ping"
    })
    const otherAccount = await post(running, "/v1/plugins/events/preview", {
      plugin: plugin.id,
      event: "test.ping",
      accountId: "someone-else"
    })
    const { matched } = decode(PreviewResponse)(preview.body)
    const record = await jsonRequest(running.server, `/v1/plugins/events/${matched[0]!.eventId}`)
    const bystander = decode(PluginEventSubscription)(
      (
        await subscribe(running, {
          sessionId: bystanderChat,
          filter: 'level == "never"'
        })
      ).body
    )
    const forSession = await jsonRequest(
      running.server,
      `/v1/plugins/events/subscriptions?sessionId=${watcher}`
    )
    const everyone = await jsonRequest(running.server, "/v1/plugins/events/subscriptions")
    const removed = await jsonRequest(
      running.server,
      `/v1/plugins/events/subscriptions/${created.id}`,
      {
        method: "DELETE"
      }
    )

    expect(decode(TypesResponse)(types.body).types.map((type) => type.name)).toEqual([
      "test.counter"
    ])
    expect(preview.body).toEqual({
      explained: 'level is "warn"',
      scanned: 1,
      matched: [expect.any(Object)]
    })
    expect(unfiltered.body).toMatchObject({ explained: "every event", scanned: 1 })
    expect(otherAccount.body).toMatchObject({ scanned: 0, matched: [] })
    expect(decode(PluginEventRecord)(record.body)).toMatchObject({
      plugin: plugin.id,
      event: "test.ping"
    })
    expect(decode(PluginEventSubscriptionsResponse)(forSession.body).subscriptions).toEqual([
      created
    ])
    expect(
      decode(PluginEventSubscriptionsResponse)(everyone.body).subscriptions.map(
        (subscription) => subscription.id
      )
    ).toEqual(expect.arrayContaining([created.id, bystander.id]))
    expect(removed.body).toEqual({ removed: true })
  })

  it("explains requests it can't serve", async () => {
    const running = await startPluginServer()
    await installTestEvents(running)
    const watcher = await createChat(running, "Watcher")

    const invalid = await subscribe(running, { sessionId: watcher, filter: "level == 3" })
    const missing = await jsonRequest(running.server, "/v1/plugins/events/feedface")
    const unrouted = await jsonRequest(running.server, "/v1/plugins/events/subscriptions/some-id")
    const wrongMethod = await jsonRequest(running.server, "/v1/plugins/events/feedface", {
      method: "PUT"
    })

    expect([invalid.status, missing.status, unrouted.status, wrongMethod.status]).toEqual([
      400, 404, 404, 404
    ])
    expect(invalid.body).toEqual({ error: expect.stringMatching(/^Invalid filter: /) })
    expect(missing.body).toEqual({ error: "Event not found: feedface" })
    expect([unrouted.body, wrongMethod.body]).toEqual([
      { error: "Route not found" },
      { error: "Route not found" }
    ])
  })

  it("lists no event types on a server without plugins installed", async () => {
    const { server } = await start()

    const types = await jsonRequest(server, "/v1/plugins/events/types")

    expect(types.body).toEqual({ types: [] })
  })

  it("answers 501 when this server runs without plugins", async () => {
    const server = await startWithoutPlugins()

    const types = await jsonRequest(server, "/v1/plugins/events/types")

    expect([types.status, types.body]).toEqual([501, { error: "Plugin events unavailable" }])
  })
})

describe("plugin event accounts", () => {
  it("subscribes through the first account unless one is named by id or label", async () => {
    const running = await startPluginServer()
    await installTestEvents(running)
    await seedAccounts(running, ["Work", "Home"])
    const watcher = await createChat(running, "Watcher")

    const accounts = await Promise.all(
      [{}, { accountId: " home " }, { accountId: "account-work" }].map(
        async (choice) =>
          decode(PluginEventSubscription)(
            (await subscribe(running, { sessionId: watcher, ...choice })).body
          ).accountId
      )
    )
    const unknown = await subscribe(running, { sessionId: watcher, accountId: "Play" })

    expect(accounts).toEqual(["account-work", "account-home", "account-work"])
    expect([unknown.status, unknown.body]).toEqual([
      500,
      { error: 'No account "Play". Accounts: Work, Home' }
    ])
  })

  it("labels delivered events with their account, and still delivers when accounts can't be read", async () => {
    const running = await startPluginServer()
    const streams = watchStreams(running)
    const plugin = await installTestEvents(running)
    await seedAccounts(running, ["Work"])
    const watcher = await createChat(running, "Watcher")
    await subscribe(running, { sessionId: watcher })
    await waitFor(() => streams.length > 0)
    await emit(running, plugin.id, { message: "first" })
    await waitFor(() => pluginEventPrompts(running).length === 1)

    running.platform.attachMcp({
      ...running.mcp,
      list: async () => Promise.reject(new Error("database busy"))
    })
    const withoutAccount = decode(PluginEventSubscription)(
      (await subscribe(running, { sessionId: watcher, filter: 'message == "never"' })).body
    )
    await emit(running, plugin.id, { message: "second" })
    await waitFor(() => pluginEventPrompts(running).length === 2)

    expect(pluginEventPrompts(running)[0]).toContain('account="Work"')
    expect(withoutAccount.accountId).toBeUndefined()
    expect(pluginEventPrompts(running)[1]).toContain('"message":"second"')
    expect(pluginEventPrompts(running)[1]).not.toContain("account=")
  })
})
