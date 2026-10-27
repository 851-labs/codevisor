import { createHmac } from "node:crypto"

import { describe, expect, it } from "vitest"

import { run, waitFor } from "../../test-support.js"
import { recordField, stringField } from "../../unknown-values.js"
import { pluginKeyOf } from "../accounts/plugin-accounts.js"
import { sourceKeyOf } from "./plugin-event-source-key.js"
import {
  makePluginEventWebhooks,
  minRefreshMs,
  webhookTtlMs,
  type PluginEventWebhooks
} from "./plugin-event-webhooks.js"
import {
  eventList,
  eventsFixture,
  fakeInboxes,
  ping,
  pingPlugin,
  pingType,
  type EventsFixture,
  type RequestHandler
} from "./plugin-events-test-support.js"

const now = Date.UTC(2026, 9, 27, 9)
const nowSeconds = now / 1000
const hourMs = 60 * 60_000

const sign = (secret: string, id: string, timestamp: number, body: string): string =>
  `v1,${createHmac("sha256", Buffer.from(secret.slice("whsec_".length), "base64"))
    .update(`${id}.${timestamp}.${body}`)
    .digest("base64")}`

const webhookFixture = async (
  options: {
    readonly deviceId?: string | undefined
    readonly subscribe?: RequestHandler
    readonly unsubscribe?: RequestHandler
    readonly accountId?: string | undefined
  } = {}
) => {
  const fixture = await eventsFixture({ now: () => now })
  const cloud = fakeInboxes()
  const hooks = await pingPlugin(fixture, "Remote", {
    "events/list": eventList(pingType({ delivery: ["webhook"] })),
    "events/subscribe": options.subscribe ?? (() => ({})),
    "events/unsubscribe": options.unsubscribe ?? (() => ({}))
  })
  let webhooks: PluginEventWebhooks | undefined
  const events = fixture.engine({
    webhooks: (ingest) => {
      webhooks = makePluginEventWebhooks({
        db: fixture.db,
        connections: fixture.fake.connections,
        inboxes: cloud.inboxes,
        ingest,
        timers: fixture.clock.timers,
        deviceId: () => ("deviceId" in options ? options.deviceId : "device-1"),
        pluginKey: pluginKeyOf,
        now: () => now
      })
      return webhooks
    }
  })
  const accountId = "accountId" in options ? options.accountId : "work"
  const subscribe = () =>
    events.subscribe({
      sessionId: fixture.session.id,
      plugin: hooks.id,
      event: "ping",
      ...(accountId === undefined ? {} : { accountId })
    })
  return { fixture, cloud, hooks, events, subscribe, receiver: () => webhooks! }
}

const registrations = (fixture: EventsFixture) => fixture.fake.requestsOf("events/subscribe")

const deliveryField = (request: { readonly params: unknown } | undefined, key: string): string =>
  stringField(recordField(request?.params, "delivery"), key)!

const secretOf = (fixture: EventsFixture): string =>
  deliveryField(registrations(fixture)[0], "secret")

const inboxIdOf = (fixture: EventsFixture): string =>
  deliveryField(registrations(fixture)[0], "url").split("/").at(-1)!

const delivery = (
  fixture: EventsFixture,
  body: unknown,
  headers: { readonly id?: string; readonly timestamp?: number; readonly signature?: string } = {}
) => {
  const text = JSON.stringify(body)
  const id = headers.id ?? "msg-1"
  const timestamp = headers.timestamp ?? nowSeconds
  return {
    itemId: `item-${id}`,
    inboxId: inboxIdOf(fixture),
    method: "POST",
    headers: {
      "Webhook-Id": id,
      "webhook-timestamp": String(timestamp),
      "webhook-signature": headers.signature ?? sign(secretOf(fixture), id, timestamp, text)
    },
    body: Buffer.from(text).toString("base64"),
    receivedAt: "2026-10-27T09:00:00.000Z"
  }
}

describe("webhook delivery for remote plugins", () => {
  it("registers a signed webhook through this Mac's inbox and renews it before it expires", async () => {
    const { fixture, cloud, hooks, subscribe } = await webhookFixture({
      subscribe: (params) =>
        params.cursor === null
          ? { cursor: "c1", refreshBefore: new Date(now + 3 * hourMs).toISOString() }
          : {}
    })

    const subscription = await subscribe()
    ;(await fixture.clock.nextSleep(1)).wake()
    await fixture.clock.nextSleep(2)

    const ingress = cloud.calls[0]!.split(" ").at(-1)!
    expect(cloud.calls).toEqual([
      `ensure ${hooks.name} work ${ingress}`,
      `subscribe work-${ingress}`
    ])
    expect(ingress).toMatch(/^events\.device-1\.[0-9a-f]{16}$/)
    const webhookDelivery = {
      mode: "webhook",
      url: `https://inbox.example/i/work-${ingress}`,
      secret: expect.stringMatching(/^whsec_/)
    }
    expect(registrations(fixture).map((request) => [request.params, request.accountId])).toEqual([
      [
        {
          name: "ping",
          arguments: {},
          delivery: webhookDelivery,
          cursor: null,
          ttlMs: webhookTtlMs
        },
        "work"
      ],
      [
        {
          name: "ping",
          arguments: {},
          delivery: webhookDelivery,
          cursor: "c1",
          ttlMs: webhookTtlMs
        },
        "work"
      ]
    ])
    expect(fixture.clock.delays()).toEqual([2 * hourMs, webhookTtlMs - hourMs])
    expect(subscription.accountId).toBe("work")
  })

  it("renews no sooner than a minute when the plugin asks for an early refresh", async () => {
    const { fixture, subscribe } = await webhookFixture({
      subscribe: () => ({ refreshBefore: new Date(now).toISOString() })
    })

    await subscribe()
    await fixture.clock.nextSleep(1)

    expect(fixture.clock.delays()).toEqual([minRefreshMs])
  })

  it("unregisters from the plugin and the inbox when the subscription goes, keeping its secret", async () => {
    const { fixture, cloud, events, subscribe } = await webhookFixture()
    const first = await subscribe()
    await fixture.clock.nextSleep(1)
    const secret = secretOf(fixture)

    await events.unsubscribe(first.id)
    await waitFor(() => cloud.calls.some((call) => call.startsWith("unsubscribe")))
    await subscribe()
    await waitFor(() => registrations(fixture).length === 2)

    expect(fixture.fake.requestsOf("events/unsubscribe")).toEqual([
      expect.objectContaining({
        params: {
          name: "ping",
          arguments: {},
          delivery: { url: expect.stringContaining("work-events.") }
        },
        accountId: "work"
      })
    ])
    const secrets = registrations(fixture).map((request) => deliveryField(request, "secret"))
    expect(secrets).toEqual([secret, secret])
  })

  it("still releases the inbox when the plugin is gone and the cloud can't be reached", async () => {
    const { fixture, cloud, hooks, events, subscribe } = await webhookFixture()
    const subscription = await subscribe()
    await fixture.clock.nextSleep(1)
    fixture.fake.remove(hooks.id)
    cloud.failUnsubscribes()

    await events.unsubscribe(subscription.id)
    await waitFor(() => cloud.calls.some((call) => call.startsWith("unsubscribe")))

    expect(fixture.fake.requestsOf("events/unsubscribe")).toEqual([])
  })

  it("still releases the inbox when the plugin refuses to unregister an account-less webhook", async () => {
    const { fixture, cloud, events, subscribe } = await webhookFixture({
      accountId: undefined,
      unsubscribe: () => {
        throw new Error("unknown subscription")
      }
    })
    const subscription = await subscribe()
    await fixture.clock.nextSleep(1)

    await events.unsubscribe(subscription.id)
    await waitFor(() => cloud.calls.some((call) => call.startsWith("unsubscribe")))

    expect(cloud.calls[0]).toMatch(/^ensure Remote {2}events\.device-1\./)
    expect(fixture.fake.requestsOf("events/unsubscribe")).toEqual([
      expect.not.objectContaining({ accountId: expect.anything() })
    ])
  })

  it("waits for Codevisor Cloud before registering a webhook", async () => {
    const { fixture, cloud, subscribe } = await webhookFixture({ deviceId: undefined })

    await subscribe()
    await fixture.clock.nextSleep(1)

    expect(fixture.clock.delays()).toEqual([5_000])
    expect(cloud.calls).toEqual([])
  })

  it("ingests each verified delivery once and saves its cursor", async () => {
    const { fixture, hooks, subscribe, receiver } = await webhookFixture()
    await subscribe()
    await fixture.clock.nextSleep(1)
    const event = { ...ping("e1"), cursor: "c9" }

    await receiver().receive(delivery(fixture, event))
    await receiver().receive(delivery(fixture, event))
    await receiver().receive(delivery(fixture, { ...ping("e2"), cursor: "c10" }, { id: "msg-2" }))

    const source = { serverId: hooks.id, accountId: "work", eventName: "ping", arguments: {} }
    expect(fixture.outbox.delivered).toHaveLength(2)
    expect(await run(fixture.db.pluginEventCursor(sourceKeyOf(source)))).toBe("c10")
  })

  it("ignores deliveries that are unsigned, stale, forged or for another inbox", async () => {
    const { fixture, subscribe, receiver } = await webhookFixture()
    await subscribe()
    await fixture.clock.nextSleep(1)
    const event = ping("e1")
    const signed = delivery(fixture, event)
    const { "webhook-signature": _signature, ...unsigned } = signed.headers
    const { "Webhook-Id": _id, ...anonymous } = signed.headers

    await receiver().receive({ ...signed, headers: unsigned })
    await receiver().receive({ ...signed, headers: anonymous })
    await receiver().receive({
      ...signed,
      headers: { ...signed.headers, "webhook-timestamp": "soon" }
    })
    await receiver().receive(delivery(fixture, event, { timestamp: nowSeconds - 301 }))
    await receiver().receive(delivery(fixture, event, { signature: "v1,forged" }))
    await receiver().receive({ ...signed, inboxId: "someone-elses-inbox" })

    expect(fixture.outbox.delivered).toEqual([])
  })

  it("accepts any one valid signature among several", async () => {
    const { fixture, subscribe, receiver } = await webhookFixture()
    await subscribe()
    await fixture.clock.nextSleep(1)
    const valid = delivery(fixture, ping("e1"))

    await receiver().receive({
      ...valid,
      headers: {
        ...valid.headers,
        "webhook-signature": `v1,rotated-away ${valid.headers["webhook-signature"]}`
      }
    })

    expect(fixture.outbox.delivered).toHaveLength(1)
  })

  it("moves the cursor past a gap and ignores other envelopes", async () => {
    const { fixture, hooks, subscribe, receiver } = await webhookFixture()
    await subscribe()
    await fixture.clock.nextSleep(1)
    const source = { serverId: hooks.id, accountId: "work", eventName: "ping", arguments: {} }

    await receiver().receive(delivery(fixture, { type: "gap", cursor: "after-gap" }, { id: "gap" }))
    await receiver().receive(delivery(fixture, { type: "gap" }, { id: "gap-2" }))
    await receiver().receive(
      delivery(fixture, { type: "terminated", cursor: "ignored" }, { id: "end" })
    )
    await receiver().receive(delivery(fixture, 5, { id: "number" }))

    expect(await run(fixture.db.pluginEventCursor(sourceKeyOf(source)))).toBe("after-gap")
    expect(fixture.outbox.delivered).toEqual([])
  })
})
