import { decode } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { fakeOAuthMcpServer, manualOAuthClock } from "../../infra/mcp-oauth-test-support.js"
import { bodyId, jsonRequest, listSubjectEvents, waitFor } from "../../test-support.js"
import { field, isRecord, stringField } from "../../unknown-values.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import { createChat, post, startPluginServer, type PluginServer } from "../plugin-test-support.js"

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
    const isSetup = stringField(payload, "questionId")?.startsWith("plugin-setup:") === true
    if (event.kind !== "session.output" || !isRecord(payload) || !isSetup) return []
    return [payload]
  })

const asArray = (value: unknown): ReadonlyArray<unknown> => (Array.isArray(value) ? value : [])

const ItemsResponse = Schema.Struct({ items: Schema.Array(Schema.Unknown) })

const requestSetup = (running: PluginServer, sessionId: string, plugin: string, waitMs?: number) =>
  post(running, "/v1/plugins/setup-requests", {
    sessionId,
    plugin,
    reason,
    ...(waitMs === undefined ? {} : { waitMs })
  })

const askedQuestion = async (running: PluginServer, sessionId: string): Promise<string> => {
  await waitFor(() => setupUpdates(running, sessionId).length > 0)
  return stringField(setupUpdates(running, sessionId)[0], "questionId")!
}

const answer = (
  running: PluginServer,
  sessionId: string,
  questionId: string,
  body: Record<string, unknown>
) =>
  post(
    running,
    `/v1/sessions/${sessionId}/questions/${encodeURIComponent(questionId)}/answer`,
    body
  )

const choose = (label: string) => ({
  outcome: "answered",
  answers: { plugin_setup: { answers: [label] } }
})

describe("plugin setup requests", () => {
  it("reports a plugin that is already ready as connected without asking", async () => {
    const running = await startPluginServer()
    const pinger = await savePluginRow(running.services.db, "Pinger")
    const chat = await createChat(running, "Chat")

    const requested = await requestSetup(running, chat, "pinger", 0)

    expect(requested.body).toEqual({
      outcome: "connected",
      plugin: pinger.id,
      name: "Pinger",
      accounts: []
    })
    expect(setupUpdates(running, chat)).toEqual([])
  })

  it("asks once in the chat and reports pending when nobody answers in time", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")

    const first = await requestSetup(running, chat, grafanaId, 0)
    const again = await requestSetup(running, chat, "Grafana", -5)

    expect([first.body, again.body]).toEqual([
      { outcome: "pending", plugin: grafanaId, name: "Grafana", accounts: [] },
      { outcome: "pending", plugin: grafanaId, name: "Grafana", accounts: [] }
    ])
    expect(setupUpdates(running, chat)).toEqual([
      {
        sessionUpdate: "question",
        chatItemId: expect.any(String),
        questionId: expect.stringMatching(/^plugin-setup:/),
        questions: [
          {
            id: "plugin_setup",
            header: "Grafana",
            question: reason,
            options: [{ label: "Set Up" }, { label: "Not Now" }],
            multiSelect: false,
            allowsOther: false,
            presentation: "pluginSetup",
            pluginSetup: {
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
        ]
      }
    ])
  })

  it("connects once the plugin is installed and an account is added", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")

    const requesting = requestSetup(running, chat, grafanaId)
    const questionId = await askedQuestion(running, chat)
    const installed = await post(
      running,
      `/v1/plugins/catalog/${encodeURIComponent(grafanaId)}/install`
    )
    const serverId = bodyId(installed)
    await post(running, `/v1/plugins/${serverId}/accounts`, {
      values: { url: "https://grafana.example.com", token: "glsa_secret" }
    })

    expect((await requesting).body).toEqual({
      outcome: "connected",
      plugin: serverId,
      name: "Grafana",
      accounts: ["grafana.example.com"]
    })
    expect(
      setupUpdates(running, chat).map((update) => [
        update["sessionUpdate"],
        update["questionId"],
        update["outcome"]
      ])
    ).toEqual([
      ["question", questionId, undefined],
      ["question_resolved", questionId, "autoResolved"]
    ])
  })

  it("keeps waiting after Set Up and declines on Not Now", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")

    const requesting = requestSetup(running, chat, grafanaId, 60_000)
    const questionId = await askedQuestion(running, chat)
    await answer(running, chat, questionId, choose("Set Up"))
    const stillAsking = setupUpdates(running, chat).length
    await answer(running, chat, questionId, choose("Not Now"))

    expect((await requesting).body).toMatchObject({ outcome: "declined", plugin: grafanaId })
    expect(stillAsking).toBe(1)
    expect(setupUpdates(running, chat).at(-1)).toMatchObject({
      sessionUpdate: "question_resolved",
      questionId,
      outcome: "cancelled"
    })
  })

  it("declines when the question is dismissed, ignoring answers from another chat", async () => {
    const running = await startPluginServer()
    const chat = await createChat(running, "Chat")
    const other = await createChat(running, "Other chat")

    const requesting = requestSetup(running, chat, grafanaId, 60_000)
    const questionId = await askedQuestion(running, chat)
    const fromOther = await answer(running, other, questionId, choose("Not Now"))
    await answer(running, chat, questionId, { outcome: "cancelled" })

    expect(fromOther.status).toBe(202)
    expect(running.agents.questionAnswers).toEqual([
      [expect.any(String), questionId, expect.objectContaining({ outcome: "answered" })]
    ])
    expect((await requesting).body).toMatchObject({ outcome: "declined" })
  })

  it("asks to sign in to an installed custom plugin by its server", async () => {
    const running = await startPluginServer()
    const provider = await fakeOAuthMcpServer(manualOAuthClock())
    const tracker = await running.mcp.create({ ...trackerServer, url: provider.url })
    const chat = await createChat(running, "Chat")

    const requested = await requestSetup(running, chat, "Tracker", 0)

    expect(requested.body).toMatchObject({
      outcome: "pending",
      plugin: tracker.id,
      name: "Tracker"
    })
    const [question] = Array.from(asArray(field(setupUpdates(running, chat)[0], "questions")))
    const pluginSetup = field(question, "pluginSetup")
    expect(pluginSetup).toMatchObject({
      plugin: tracker.id,
      serverId: tracker.id,
      name: "Tracker",
      auth: "mcpOAuth"
    })
    expect(pluginSetup).not.toHaveProperty("catalogId")
  })

  it("tells the model why sign-in can't start instead of showing a card", async () => {
    const running = await startPluginServer()
    await running.mcp.create({ ...trackerServer, url: "http://127.0.0.1:9/mcp" })
    const chat = await createChat(running, "Chat")

    const requested = await requestSetup(running, chat, "Tracker", 0)

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

    const requested = await requestSetup(running, chat, "Tracker", 0)

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

    const unknown = await requestSetup(running, chat, "io.example/nope", 0)

    expect([unknown.status, unknown.body]).toEqual([
      404,
      { error: 'No plugin named "io.example/nope". Search with plugins.search.' }
    ])
  })
})
