import { decode } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { fakeOAuthMcpServer, manualOAuthClock } from "../../infra/mcp-oauth-test-support.js"
import { bodyId, jsonRequest, listSubjectEvents, run, waitFor } from "../../test-support.js"
import { field, isRecord, stringField } from "../../unknown-values.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import {
  createChat,
  post,
  startPluginServer,
  testEventsId,
  type PluginServer
} from "../plugin-test-support.js"

const grafanaId = "dev.codevisor/grafana"
const trackerServer = {
  authType: "oauth",
  enabled: true,
  name: "Tracker",
  transport: "http"
} as const
const reason = "To watch your production alerts"

const setupUpdates = (
  running: PluginServer,
  sessionId: string
): ReadonlyArray<Readonly<Record<string, unknown>>> =>
  listSubjectEvents(running.services, sessionId).flatMap((event) => {
    const payload = event.payload
    const isSetup = stringField(payload, "sessionUpdate") === "plugin_setup"
    if (event.kind !== "session.output" || !isRecord(payload) || !isSetup) return []
    return [payload]
  })

const setupStates = (running: PluginServer, sessionId: string): ReadonlyArray<unknown> =>
  setupUpdates(running, sessionId).map((update) => update["state"])

const finishedPrompts = (running: PluginServer): ReadonlyArray<string> =>
  running.agents.prompts.flatMap(([, input]) =>
    typeof input === "string" && input.includes('type="plugin.setup_finished"') ? [input] : []
  )

const ItemsResponse = Schema.Struct({ items: Schema.Array(Schema.Unknown) })

const requestSetup = (running: PluginServer, sessionId: string, plugin: string) =>
  post(running, "/v1/plugins/setup-requests", { sessionId, plugin, reason })

const installGrafana = async (running: PluginServer): Promise<string> =>
  bodyId(await post(running, `/v1/plugins/catalog/${encodeURIComponent(grafanaId)}/install`))

const addGrafanaAccount = (running: PluginServer, serverId: string) =>
  post(running, `/v1/plugins/${serverId}/accounts`, {
    values: { url: "https://grafana.example.com", token: "glsa_secret" }
  })

describe("plugin setup requests", () => {
  it("reports a plugin that is already set up as ready without showing a card", async () => {
    const running = await startPluginServer()
    const pinger = await savePluginRow(running.services.db, "Pinger")
    const chat = await createChat(running, "Chat")

    const requested = await requestSetup(running, chat, "pinger")

    expect(requested.body).toEqual({
      outcome: "ready",
      plugin: pinger.id,
      name: "Pinger",
      accounts: [],
      next: "Pinger is ready to use. No card was shown."
    })
    expect(setupUpdates(running, chat)).toEqual([])
  })

  it("shows one card and returns at once, however often it is asked", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")

    const first = await requestSetup(running, chat, grafanaId)
    const again = await requestSetup(running, chat, "Grafana")

    expect(first.body).toEqual({
      outcome: "requested",
      needs: "install",
      plugin: grafanaId,
      name: "Grafana",
      accounts: [],
      next: expect.stringContaining('<codevisor-event type="plugin.setup_finished">')
    })
    expect(again.body).toEqual(first.body)
    expect(setupUpdates(running, chat)).toEqual([
      {
        sessionUpdate: "plugin_setup",
        chatItemId: expect.any(String),
        setupId: expect.stringMatching(/^plugin-setup:/),
        state: "pending",
        request: {
          plugin: grafanaId,
          catalogId: grafanaId,
          publisher: expect.any(String),
          description: expect.stringContaining("Grafana"),
          name: "Grafana",
          reason,
          auth: "fields",
          capabilities: expect.objectContaining({
            ingress: [{ name: "alerts", title: "Grafana alert webhook" }]
          }),
          machine: { id: "server-a", name: "Local Codevisor" }
        }
      }
    ])
  })

  it("leaves the chat free: the card is not a question waiting on the user", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")

    await requestSetup(running, chat, grafanaId)

    const page = await run(running.services.db.getTranscriptPage(chat, undefined, 10))
    expect(page.pendingQuestion).toBeUndefined()
    expect(page.items.flatMap((item) => item.pluginSetups ?? [])).toEqual([
      expect.objectContaining({ state: "pending", request: expect.objectContaining({ reason }) })
    ])
  })

  it("marks the card connected and tells the agent once an account is added", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")
    await requestSetup(running, chat, grafanaId)

    const serverId = await installGrafana(running)
    const installedOnly = setupStates(running, chat)
    await addGrafanaAccount(running, serverId)
    await waitFor(() => finishedPrompts(running).length > 0)

    expect(installedOnly).toEqual(["pending"])
    expect(setupStates(running, chat)).toEqual(["pending", "connected"])
    expect(field(setupUpdates(running, chat)[1]?.["request"], "auth")).toBe("fields")
    expect(finishedPrompts(running)).toEqual([
      [
        `<codevisor-event machine="Local Codevisor" machineId="server-a" type="plugin.setup_finished" plugin="Grafana" pluginId="${serverId}">`,
        "The user finished setting up Grafana from the card you showed. It's installed and ready to use.",
        "Signed-in accounts: grafana.example.com.",
        `Carry on with what you needed it for. plugins.describe({ plugin: "${serverId}" }) lists its tools.`,
        "</codevisor-event>"
      ].join("\n")
    ])
    const page = await run(running.services.db.getTranscriptPage(chat, undefined, 10))
    expect(
      page.items.flatMap((item) => item.pluginSetups ?? []).map((setup) => setup.state)
    ).toEqual(["connected"])
  })

  it("offers only the connect step for a plugin that is installed but not connected", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")
    const serverId = await installGrafana(running)

    const requested = await requestSetup(running, chat, "Grafana")
    await addGrafanaAccount(running, serverId)
    await waitFor(() => finishedPrompts(running).length > 0)

    expect(requested.body).toMatchObject({ outcome: "requested", needs: "connect" })
    expect(setupUpdates(running, chat)[0]).toMatchObject({
      request: { serverId, catalogId: grafanaId }
    })
    expect(setupStates(running, chat)).toEqual(["pending", "connected"])
  })

  it("records on the finished card whether the plugin ended up with an account", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")
    await requestSetup(running, chat, "Test Events")

    await post(running, `/v1/plugins/catalog/${encodeURIComponent(testEventsId)}/install`)
    await waitFor(() => finishedPrompts(running).length > 0)

    expect(setupUpdates(running, chat).map((update) => field(update["request"], "auth"))).toEqual([
      "none",
      "none"
    ])
    expect(finishedPrompts(running)[0]).not.toContain("Signed-in accounts")
  })

  it("shows no card for a plugin that is installed but turned off", async () => {
    const running = await startPluginServer()
    await savePluginRow(running.services.db, "Pinger", { enabled: false })
    const chat = await createChat(running, "Chat")

    const requested = await requestSetup(running, chat, "Pinger")

    expect(requested.body).toMatchObject({
      outcome: "disabled",
      next: expect.stringContaining("Settings › Plugins")
    })
    expect(setupUpdates(running, chat)).toEqual([])
  })

  it("asks to sign in to an installed custom plugin by its server", async () => {
    const running = await startPluginServer()
    const provider = await fakeOAuthMcpServer(manualOAuthClock())
    const tracker = await running.mcp.create({ ...trackerServer, url: provider.url })
    const chat = await createChat(running, "Chat")

    const requested = await requestSetup(running, chat, "Tracker")

    expect(requested.body).toMatchObject({
      outcome: "requested",
      needs: "connect",
      plugin: tracker.id,
      name: "Tracker"
    })
    const shown = field(setupUpdates(running, chat)[0], "request")
    expect(shown).toMatchObject({
      plugin: tracker.id,
      serverId: tracker.id,
      name: "Tracker",
      auth: "mcpOAuth"
    })
    expect(shown).not.toHaveProperty("catalogId")
  })

  it("tells the model why sign-in can't start instead of showing a card", async () => {
    const running = await startPluginServer()
    await running.mcp.create({ ...trackerServer, url: "http://127.0.0.1:9/mcp" })
    const chat = await createChat(running, "Chat")

    const requested = await requestSetup(running, chat, "Tracker")

    expect(requested.status).toBe(409)
    expect(stringField(requested.body, "error")).toMatch(
      /^Tracker can't start sign-in on .+: .+\. No setup card was shown\.$/
    )
    expect(setupUpdates(running, chat)).toEqual([])
  })

  it("explains when the machine's plugins can't be read", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")
    vi.spyOn(running.mcp, "list").mockRejectedValue(new Error("database busy"))

    const requested = await requestSetup(running, chat, "Tracker")

    expect(requested.status).toBe(503)
    expect(stringField(requested.body, "error")).toMatch(
      /^Couldn't read the plugins on .+: database busy\. No setup card was shown\.$/
    )
    expect(setupUpdates(running, chat)).toEqual([])
  })

  it("lists no accounts while the account store can't be read", async () => {
    const running = await startPluginServer()
    await savePluginRow(running.services.db, "Grafana", { catalogId: grafanaId })
    running.platform.attachMcp({
      ...running.mcp,
      list: () => Promise.reject(new Error("database busy"))
    })

    const searched = await jsonRequest(running.server, "/v1/plugins/search?query=grafana")

    expect(decode(ItemsResponse)(searched.body).items).toContainEqual(
      expect.objectContaining({ name: "Grafana", installed: true, accounts: [], ready: false })
    )
  })

  it("explains plugins it can't find", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")

    const unknown = await requestSetup(running, chat, "io.example/nope")

    expect([unknown.status, unknown.body]).toEqual([
      404,
      { error: 'No plugin named "io.example/nope". Search with plugins.search.' }
    ])
  })
})
