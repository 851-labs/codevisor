import { createHash } from "node:crypto"

import { describe, expect, it } from "vitest"

import { pluginKeyOf } from "../accounts/plugin-accounts.js"
import { makePluginEventIngress } from "./plugin-event-ingress.js"
import { signOutOfPlugin } from "./plugin-events-boot.js"
import {
  capabilitiesWith,
  eventsFixture,
  fakeInboxes,
  savePluginRow,
  type EventsFixture
} from "./plugin-events-test-support.js"

const grafanaFixture = async () => {
  const fixture = await eventsFixture()
  const grafana = await savePluginRow(fixture.db, "Grafana", {
    catalogId: "codevisor.grafana",
    capabilities: capabilitiesWith({
      ingress: [{ name: "alerts", title: "Grafana alert webhook" }, { name: "silences" }]
    })
  })
  const plain = await savePluginRow(fixture.db, "Plain")
  const undiscovered = {
    ...(await savePluginRow(fixture.db, "Undiscovered")),
    capabilities: undefined
  }
  fixture.fake.add(grafana, { "codevisor/webhook": () => ({ accepted: 1 }) })
  fixture.fake.add(plain, {})
  fixture.fake.add(undiscovered, {})
  const cloud = fakeInboxes()
  const ingress = makePluginEventIngress({
    connections: fixture.fake.connections,
    inboxes: cloud.inboxes,
    pluginKey: pluginKeyOf,
    identity: async () => undefined
  })
  return { fixture, grafana, plain, undiscovered, cloud, ingress }
}

const gmailFixture = async () => {
  const fixture = await eventsFixture()
  const gmail = await savePluginRow(fixture.db, "Gmail", {
    catalogId: "dev.codevisor/gmail",
    capabilities: capabilitiesWith({
      ingress: [{ name: "gmail", title: "Gmail push notifications", route: "gmail" }]
    })
  })
  const removed: Array<string> = []
  fixture.fake.add(gmail, {
    "codevisor/account/remove": (params) => {
      removed.push(JSON.stringify(params))
      return {}
    }
  })
  const cloud = fakeInboxes()
  const identities: Record<string, string> = { work: " Dylan@851.sh " }
  const ingress = makePluginEventIngress({
    connections: fixture.fake.connections,
    inboxes: cloud.inboxes,
    pluginKey: pluginKeyOf,
    identity: async (_serverId, accountId) => identities[accountId]
  })
  return { fixture, gmail, cloud, ingress, removed }
}

const addressKey = createHash("sha256").update("dylan@851.sh").digest("hex")

const source = (serverId: string, accountId?: string, eventName = "alert.firing") => ({
  serverId,
  ...(accountId === undefined ? {} : { accountId }),
  eventName,
  arguments: {}
})

const webhookFor = (inboxId: string) => ({
  itemId: "item-1",
  inboxId,
  method: "POST",
  headers: { authorization: "Bearer secret" },
  body: "eyJhbGVydHMiOltdfQ==",
  receivedAt: "2026-10-27T09:00:00.000Z"
})

const webhookRequests = (fixture: EventsFixture) => fixture.fake.requestsOf("codevisor/webhook")

describe("plugin webhook ingress", () => {
  it("subscribes this Mac to an account's inboxes only while that account has subscriptions", async () => {
    const { grafana, plain, undiscovered, cloud, ingress } = await grafanaFixture()

    await ingress.refresh([
      source(grafana.id, "work"),
      source(grafana.id, "work", "alert.resolved"),
      source(grafana.id),
      source(plain.id, "work"),
      source(undiscovered.id, "work"),
      source("removed-plugin", "work")
    ])
    const afterFirst = cloud.calls.splice(0)
    await ingress.refresh([source(grafana.id, "work")])
    const afterSecond = cloud.calls.splice(0)
    await ingress.refresh([])

    expect(afterFirst).toEqual([
      "ensure codevisor.grafana work alerts",
      "ensure codevisor.grafana work silences",
      "subscribe work-alerts",
      "subscribe work-silences"
    ])
    expect(afterSecond).toEqual([
      "ensure codevisor.grafana work alerts",
      "ensure codevisor.grafana work silences"
    ])
    expect(cloud.calls).toEqual(["unsubscribe work-alerts", "unsubscribe work-silences"])
  })

  it("lists an account's webhook URLs and nothing for an unknown plugin", async () => {
    const { grafana, undiscovered, ingress } = await grafanaFixture()

    const urls = await ingress.urls(grafana.id, "work")
    const unknown = await ingress.urls("missing", "work")
    const notYetDiscovered = await ingress.urls(undiscovered.id, "work")

    expect(urls).toEqual([
      {
        name: "alerts",
        title: "Grafana alert webhook",
        url: "https://inbox.example/i/work-alerts"
      },
      { name: "silences", url: "https://inbox.example/i/work-silences" }
    ])
    expect([unknown, notYetDiscovered]).toEqual([[], []])
  })

  it("forwards a delivered webhook to the plugin and account that own the inbox", async () => {
    const { fixture, grafana, ingress } = await grafanaFixture()
    await ingress.urls(grafana.id, "work")

    await ingress.deliver(webhookFor("work-alerts"))
    await ingress.deliver(webhookFor("someone-elses-inbox"))

    expect(webhookRequests(fixture)).toEqual([
      {
        serverId: grafana.id,
        method: "codevisor/webhook",
        params: {
          ingress: "alerts",
          request: {
            method: "POST",
            headers: { authorization: "Bearer secret" },
            body: "eyJhbGVydHMiOltdfQ==",
            receivedAt: "2026-10-27T09:00:00.000Z"
          }
        },
        accountId: "work"
      }
    ])
  })
})

describe("routed ingress", () => {
  it("routes an account's inbox by the hash of its address and hands the plugin the route settings", async () => {
    const { gmail, cloud, ingress } = await gmailFixture()

    const meta = await ingress.meta(gmail.id, "work")
    const urls = await ingress.urls(gmail.id, "work")

    expect(meta).toEqual({
      "dev.codevisor/ingress": {
        ingress: [
          {
            name: "gmail",
            url: "https://inbox.example/i/work-gmail",
            route: { name: "gmail", topic: "projects/test/topics/gmail" }
          }
        ]
      }
    })
    expect(urls).toEqual([])
    expect(cloud.calls.slice(0, 2)).toEqual([
      "ensure dev.codevisor/gmail work gmail",
      `route work-gmail gmail ${addressKey}`
    ])
  })

  it("leaves an account without a known address unrouted, and unknown plugins without details", async () => {
    const { gmail, cloud, ingress } = await gmailFixture()

    const unrouted = await ingress.meta(gmail.id, "home")
    const unknown = await ingress.meta("missing", "work")

    expect(unrouted).toEqual({
      "dev.codevisor/ingress": {
        ingress: [{ name: "gmail", url: "https://inbox.example/i/home-gmail" }]
      }
    })
    expect(unknown).toEqual({})
    expect(cloud.calls).toEqual(["ensure dev.codevisor/gmail home gmail"])
  })

  it("signs a removed account out of its plugin, then deletes its inboxes and stops routing to them", async () => {
    const { fixture, gmail, cloud, ingress, removed } = await gmailFixture()
    await ingress.refresh([source(gmail.id, "work", "message.received")])
    cloud.calls.splice(0)

    await signOutOfPlugin(fixture.fake.connections, ingress, gmail.id, "work")
    await ingress.deliver(webhookFor("work-gmail"))
    await ingress.refresh([])

    expect(removed).toEqual(["{}"])
    expect(fixture.fake.requestsOf("codevisor/account/remove")).toMatchObject([
      { accountId: "work" }
    ])
    expect(cloud.calls).toEqual(["find dev.codevisor/gmail work gmail", "remove work-gmail"])
    expect(webhookRequests(fixture)).toEqual([])
  })

  it("creates no inbox for a removed account that never had one", async () => {
    const { fixture, gmail, cloud, ingress } = await gmailFixture()

    await signOutOfPlugin(fixture.fake.connections, ingress, gmail.id, "work")

    expect(cloud.calls).toEqual(["find dev.codevisor/gmail work gmail"])
  })

  it("still deletes inboxes when the plugin can't sign out, and ignores unknown plugins", async () => {
    const { fixture, cloud, ingress } = await gmailFixture()
    const grafana = await grafanaFixture()
    await grafana.ingress.urls(grafana.grafana.id, "work")
    grafana.cloud.calls.splice(0)

    await signOutOfPlugin(
      grafana.fixture.fake.connections,
      grafana.ingress,
      grafana.grafana.id,
      "work"
    )
    await signOutOfPlugin(fixture.fake.connections, ingress, "missing", "work")

    expect(grafana.cloud.calls).toEqual([
      "find codevisor.grafana work alerts",
      "remove work-alerts",
      "find codevisor.grafana work silences",
      "remove work-silences"
    ])
    expect(cloud.calls).toEqual([])
  })
})
