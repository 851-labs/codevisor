import { QuestionSpec, type McpServer } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { observableFixture } from "../../changes-test-support.js"
import { makeEventFanout } from "../../server-context.js"
import { makeServices, run, waitFor } from "../../test-support.js"
import { field, stringField } from "../../unknown-values.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import { makePluginCatalog } from "../plugin-catalog.js"
import { fixtureCatalogOptions } from "../plugin-fixture-catalog.js"
import { pluginServices } from "../plugin-test-support.js"
import { makePluginDirectory } from "./plugin-directory.js"
import { startPluginDiscovery } from "./plugin-discovery-boot.js"
import { makePluginSetupBroker, type WaitingSetup } from "./plugin-setup.js"

const brokerFixture = async (
  options: { readonly failResolutions?: boolean; readonly asking?: () => boolean } = {}
) => {
  const { services } = await makeServices("server-a")
  const servers: Array<McpServer> = []
  const labels = new Map<string, ReadonlyArray<string>>()
  const emitted: Array<unknown> = observableFixture([])
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
  const makeBroker = (waiting: ReadonlyArray<WaitingSetup> = []) =>
    makePluginSetupBroker({
      directory,
      machine: { id: "server-a", name: "Studio" },
      emit: async (_sessionId, payload) => {
        const resolution = stringField(payload, "sessionUpdate") === "question_resolved"
        if (options.failResolutions === true && resolution) throw new Error("chat is gone")
        emitted.push(payload)
      },
      wait: () => new Promise(() => undefined),
      prepare: async () => undefined,
      isAsking: async () => options.asking?.() ?? true,
      waiting: async () => waiting
    })
  const broker = makeBroker()
  const install = async (name: string, overrides: Parameters<typeof savePluginRow>[2] = {}) => {
    const server = await savePluginRow(services.db, name, overrides)
    servers.push(server)
    return server
  }
  const questionId = async () => {
    await waitFor(() => emitted.length > 0)
    return stringField(emitted[0], "questionId")!
  }
  return { broker, makeBroker, servers, labels, emitted, install, questionId }
}

const request = { sessionId: "session-1", reason: "To read alerts", waitMs: 60_000 }

describe("plugin setup broker", () => {
  it("asks again when the earlier card is no longer waiting in the chat", async () => {
    let asking = true
    const fixture = await brokerFixture({ asking: () => asking })
    const grafana = await fixture.install("Grafana", { catalogId: "dev.codevisor/grafana" })
    const first = fixture.broker.request({ ...request, plugin: grafana.id })
    await fixture.questionId()

    asking = false
    void fixture.broker.request({ ...request, plugin: grafana.id })

    await waitFor(() => fixture.emitted.length === 2)
    expect((await first).outcome).toBe("declined")
    expect(stringField(fixture.emitted[1], "sessionUpdate")).toBe("question")
    expect(stringField(fixture.emitted[1], "questionId")).not.toBe(
      stringField(fixture.emitted[0], "questionId")
    )
  })

  it("resolves a question once when two refreshes see the plugin become ready", async () => {
    const fixture = await brokerFixture()
    const grafana = await fixture.install("Grafana", { catalogId: "dev.codevisor/grafana" })
    const requesting = fixture.broker.request({ ...request, plugin: grafana.id })
    await fixture.questionId()

    fixture.labels.set(grafana.id, ["grafana.example.com"])
    await Promise.all([fixture.broker.refresh(), fixture.broker.refresh()])

    expect((await requesting).outcome).toBe("connected")
    expect(fixture.emitted.map((update) => stringField(update, "sessionUpdate"))).toEqual([
      "question",
      "question_resolved"
    ])
  })

  it("still finishes a declined setup when the chat can't show the resolution", async () => {
    const fixture = await brokerFixture({ failResolutions: true })
    const grafana = await fixture.install("Grafana", { catalogId: "dev.codevisor/grafana" })
    const requesting = fixture.broker.request({ ...request, plugin: grafana.id })

    const handled = await fixture.broker.answer("session-1", await fixture.questionId(), {
      outcome: "cancelled"
    })

    expect(handled).toBe(true)
    expect((await requesting).outcome).toBe("declined")
  })

  it("names a plugin that disappeared meanwhile by what was asked for", async () => {
    const fixture = await brokerFixture()
    await fixture.install("Tracker", { authType: "oauth", connectionState: "needsAuthorization" })
    const requesting = fixture.broker.request({ ...request, plugin: "Tracker" })
    const questionId = await fixture.questionId()

    fixture.servers.splice(0)
    await fixture.broker.refresh()
    await fixture.broker.answer("session-1", questionId, { outcome: "cancelled" })

    expect(await requesting).toEqual({
      outcome: "declined",
      plugin: "Tracker",
      name: "Tracker",
      accounts: []
    })
  })

  it("settles setup cards left waiting by a restart once the plugin connects or on Not Now", async () => {
    const fixture = await brokerFixture()
    const grafana = await fixture.install("Grafana", { catalogId: "dev.codevisor/grafana" })
    const tracker = await fixture.install("Tracker", {
      authType: "oauth",
      connectionState: "needsAuthorization"
    })
    void fixture.broker.request({ ...request, plugin: grafana.id })
    void fixture.broker.request({ ...request, sessionId: "session-2", plugin: tracker.id })
    await waitFor(() => fixture.emitted.length === 2)
    const waiting = fixture.emitted.map((payload, index) => ({
      sessionId: `session-${index + 1}`,
      questionId: stringField(payload, "questionId")!,
      question: Schema.decodeUnknownSync(Schema.Array(QuestionSpec))(
        field(payload, "questions")
      )[0]!
    }))
    const restarted = fixture.makeBroker([
      ...waiting,
      {
        ...waiting[0]!,
        questionId: "agent-question",
        question: { ...waiting[0]!.question, id: "db" }
      }
    ])
    await restarted.adoptWaiting()

    fixture.labels.set(grafana.id, ["grafana.example.com"])
    await restarted.refresh()
    const declined = await restarted.answer("session-2", waiting[1]!.questionId, {
      outcome: "cancelled"
    })

    expect(declined).toBe(true)
    expect(await restarted.answer("session-1", "agent-question", { outcome: "cancelled" })).toBe(
      false
    )
    expect(fixture.emitted.slice(2)).toEqual([
      expect.objectContaining({ questionId: waiting[0]!.questionId, outcome: "autoResolved" }),
      expect.objectContaining({ questionId: waiting[1]!.questionId, outcome: "cancelled" })
    ])
  })

  it("describes plugins without event types when the events engine isn't running", async () => {
    const { services } = await pluginServices()
    const pinger = await savePluginRow(services.db, "Pinger", { enabled: false })
    const discovery = startPluginDiscovery(services, await run(makeEventFanout), undefined, {
      id: "server-a",
      name: "Studio"
    })!

    const described = await discovery.directory.describe(pinger.id)
    discovery.close()

    expect(described).toMatchObject({ plugin: pinger.id, eventDetails: [] })
  })
})
