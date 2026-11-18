import type { McpServer } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeEventFanout } from "../../server-context.js"
import { makeServices, run } from "../../test-support.js"
import { stringField } from "../../unknown-values.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import { makePluginCatalog } from "../plugin-catalog.js"
import { fixtureCatalogOptions } from "../plugin-fixture-catalog.js"
import { pluginServices } from "../plugin-test-support.js"
import { makePluginDirectory } from "./plugin-directory.js"
import { startPluginDiscovery } from "./plugin-discovery-boot.js"
import { makePluginSetupBroker, type ShownSetup } from "./plugin-setup.js"

const brokerFixture = async (
  options: { readonly failUpdates?: boolean; readonly failEvents?: boolean } = {}
) => {
  const { services } = await makeServices("server-a")
  const servers: Array<McpServer> = []
  const labels = new Map<string, ReadonlyArray<string>>()
  const emitted: Array<ShownSetup & { readonly state: string }> = []
  const notified: Array<readonly [sessionId: string, text: string]> = []
  const directory = makePluginDirectory({
    catalog: makePluginCatalog({
      dev: true,
      execPath: process.execPath,
      ...fixtureCatalogOptions()
    }),
    servers: async () => servers,
    accountLabels: async (serverId) => labels.get(serverId) ?? [],
    tools: async () => [],
    eventTypes: async () => []
  })
  const makeBroker = (shown: ReadonlyArray<ShownSetup> = []) =>
    makePluginSetupBroker({
      directory,
      machine: { id: "server-a", name: "Studio" },
      emit: async (sessionId, { setupId, state, request }) => {
        if (options.failUpdates === true && state === "connected") throw new Error("chat is gone")
        emitted.push({ sessionId, setupId, state, request })
      },
      notify: async (sessionId, event) => {
        if (options.failEvents === true) throw new Error("chat is archived")
        notified.push([sessionId, event.message.text])
      },
      prepare: async () => undefined,
      pending: async () => shown
    })
  const install = async (name: string, overrides: Parameters<typeof savePluginRow>[2] = {}) => {
    const server = await savePluginRow(services.db, name, overrides)
    servers.push(server)
    return server
  }
  return { broker: makeBroker(), makeBroker, servers, labels, emitted, notified, install }
}

const request = { sessionId: "session-1", reason: "To read alerts" }

const grafanaOptions = { catalogId: "dev.codevisor/grafana" }

describe("plugin setup broker", () => {
  it("finishes a setup once when two refreshes see the plugin become ready", async () => {
    const fixture = await brokerFixture()
    const grafana = await fixture.install("Grafana", grafanaOptions)
    await fixture.broker.request({ ...request, plugin: grafana.id })

    fixture.labels.set(grafana.id, ["grafana.example.com"])
    await Promise.all([fixture.broker.refresh(), fixture.broker.refresh()])

    expect(fixture.emitted.map((update) => update.state)).toEqual(["pending", "connected"])
    expect(fixture.notified.map(([sessionId]) => sessionId)).toEqual(["session-1"])
  })

  it("tells each chat that asked, and shows a new card after the first one finished", async () => {
    const fixture = await brokerFixture()
    const grafana = await fixture.install("Grafana", grafanaOptions)
    await fixture.broker.request({ ...request, plugin: grafana.id })
    await fixture.broker.request({ ...request, sessionId: "session-2", plugin: "Grafana" })

    fixture.labels.set(grafana.id, ["grafana.example.com"])
    await fixture.broker.refresh()
    fixture.labels.delete(grafana.id)
    const askedAgain = await fixture.broker.request({ ...request, plugin: grafana.id })

    expect(fixture.notified.map(([sessionId]) => sessionId)).toEqual(["session-1", "session-2"])
    expect(askedAgain.outcome).toBe("requested")
    expect(fixture.emitted.map((update) => [update.sessionId, update.state])).toEqual([
      ["session-1", "pending"],
      ["session-2", "pending"],
      ["session-1", "connected"],
      ["session-2", "connected"],
      ["session-1", "pending"]
    ])
  })

  it("still tells the agent when the chat can't show the card as connected", async () => {
    const fixture = await brokerFixture({ failUpdates: true })
    const grafana = await fixture.install("Grafana", grafanaOptions)
    await fixture.broker.request({ ...request, plugin: grafana.id })

    fixture.labels.set(grafana.id, ["grafana.example.com"])
    await fixture.broker.refresh()

    expect(fixture.notified).toHaveLength(1)
  })

  it("marks the card connected even when the agent can't be told", async () => {
    const fixture = await brokerFixture({ failEvents: true })
    const grafana = await fixture.install("Grafana", grafanaOptions)
    await fixture.broker.request({ ...request, plugin: grafana.id })

    fixture.labels.set(grafana.id, ["grafana.example.com"])
    await fixture.broker.refresh()

    expect(fixture.emitted.map((update) => update.state)).toEqual(["pending", "connected"])
  })

  it("keeps the one card when the plugin is installed after it was shown and asked for again", async () => {
    const fixture = await brokerFixture()
    await fixture.broker.request({ ...request, plugin: "Grafana" })

    const grafana = await fixture.install("Grafana", grafanaOptions)
    const again = await fixture.broker.request({ ...request, plugin: grafana.id })

    expect(again).toMatchObject({ outcome: "requested", needs: "connect" })
    expect(fixture.emitted.map((update) => update.state)).toEqual(["pending"])
  })

  it("keeps a card pending while its plugin is missing, and finishes it when it returns ready", async () => {
    const fixture = await brokerFixture()
    const tracker = await fixture.install("Tracker", {
      authType: "oauth",
      connectionState: "needsAuthorization"
    })
    await fixture.broker.request({ ...request, plugin: "Tracker" })

    fixture.servers.splice(0)
    await fixture.broker.refresh()
    const whileMissing = fixture.notified.length
    fixture.servers.push({ ...tracker, connectionState: "connected" })
    await fixture.broker.refresh()

    expect(whileMissing).toBe(0)
    expect(stringField({ text: fixture.notified[0]?.[1] }, "text")).toContain(
      `type="plugin.setup_finished" plugin="Tracker" pluginId="${tracker.id}"`
    )
  })

  it("finishes the cards a restart left pending", async () => {
    const fixture = await brokerFixture()
    const grafana = await fixture.install("Grafana", grafanaOptions)
    await fixture.broker.request({ ...request, plugin: grafana.id })
    const [shown] = fixture.emitted

    fixture.labels.set(grafana.id, ["grafana.example.com"])
    await fixture.makeBroker([shown!]).adoptPending()

    expect(fixture.emitted.at(-1)).toMatchObject({ setupId: shown!.setupId, state: "connected" })
    expect(fixture.notified.map(([sessionId]) => sessionId)).toEqual(["session-1"])
  })

  it("describes plugins without event types when the events engine isn't running", async () => {
    const { services } = await pluginServices()
    const pinger = await savePluginRow(services.db, "Pinger", { enabled: false })
    const discovery = startPluginDiscovery(
      services,
      await run(makeEventFanout),
      undefined,
      { deliver: async () => undefined, wokenBy: () => new Set(), forgetWake: () => undefined },
      { id: "server-a", name: "Studio" }
    )!

    const described = await discovery.directory.describe(pinger.id)
    discovery.close()

    expect(described).toMatchObject({ plugin: pinger.id, eventDetails: [] })
  })
})
