import { describe, expect, it } from "vitest"

import { pluginKeyOf } from "../accounts/plugin-accounts.js"
import { makePluginEventIngress } from "./plugin-event-ingress.js"
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
    pluginKey: pluginKeyOf
  })
  return { fixture, grafana, plain, undiscovered, cloud, ingress }
}

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
