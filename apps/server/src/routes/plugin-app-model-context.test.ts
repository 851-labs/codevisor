import { describe, expect, it } from "vitest"

import {
  capturedView,
  launch,
  post,
  secured,
  shell,
  type Secured
} from "../plugins/apps/plugin-app-route-support.js"
import { jsonRequest, run, waitFor } from "../test-support.js"
import { field, itemsOf } from "./response-test-support.js"

const openView = async (setup: Secured) => {
  const viewId = await capturedView(setup)
  const view = await setup.services.mcp.appView(viewId)
  const { boot } = await shell(setup, await launch(setup, `/v1/plugins/apps/${viewId}/token`))
  return { viewId, sessionId: view!.sessionId, endpoints: boot!.endpoints }
}

const prompt = (setup: Secured, sessionId: string, text: string) =>
  jsonRequest(setup.server, `/v1/sessions/${sessionId}/prompt`, {
    method: "POST",
    headers: setup.authorized,
    body: JSON.stringify({ text })
  })

describe("plugin app model context", () => {
  it("keeps only the app's latest context and doesn't wake the chat", async () => {
    const setup = await secured()
    const { endpoints, sessionId, viewId } = await openView(setup)

    const first = await post(setup, endpoints.modelContext, {
      content: [{ type: "text", text: "Loading" }]
    })
    await post(setup, endpoints.modelContext, { structuredContent: { selected: 1 } })
    await post(setup, endpoints.modelContext, { structuredContent: { selected: 1 } })
    await post(setup, endpoints.modelContext, {
      content: [{ type: "text", text: "Viewing 2 alerts" }],
      structuredContent: { selected: 2 }
    })

    expect(first).toEqual({ status: 200, body: {} })
    expect(await run(setup.services.db.listPluginAppContexts(sessionId))).toEqual([
      expect.objectContaining({
        viewId,
        plugin: "Grafana",
        tool: "show_alerts",
        context: {
          content: [{ type: "text", text: "Viewing 2 alerts" }],
          structuredContent: { selected: 2 }
        },
        revision: 3
      })
    ])
    expect(setup.agents.prompts).toEqual([])
  })

  it("adds pending context to the next message the user sends, once, out of the transcript", async () => {
    const setup = await secured()
    const { endpoints, sessionId, viewId } = await openView(setup)
    await post(setup, endpoints.modelContext, {
      content: [{ type: "text", text: "Viewing 2 alerts" }],
      structuredContent: { selected: 2 }
    })

    await prompt(setup, sessionId, "Which one is worst?")
    await waitFor(() => setup.agents.prompts.length === 1)
    await waitFor(
      async () => (await run(setup.services.db.listPluginAppContexts(sessionId))).length === 0
    )
    await prompt(setup, sessionId, "Thanks")
    await waitFor(() => setup.agents.prompts.length === 2)

    expect(setup.agents.prompts.map(([, text]) => text)).toEqual([
      `<codevisor-app-context plugin="Grafana" tool="show_alerts" viewId="${viewId}">\nViewing 2 alerts\n{"selected":2}\n</codevisor-app-context>\n\nWhich one is worst?`,
      "Thanks"
    ])
    const transcript = await jsonRequest(setup.server, `/v1/sessions/${sessionId}/transcript`, {
      headers: setup.authorized
    })
    expect(
      itemsOf(field(transcript.body, "items"))
        .filter((item) => field(item, "role") === "user")
        .map((item) => field(item, "text"))
    ).toEqual(["Which one is worst?", "Thanks"])
  })

  it("refuses context from panes and malformed updates", async () => {
    const setup = await secured()
    const { endpoints } = await openView(setup)
    const paneUrl = await launch(setup, `/v1/plugins/${setup.serverId}/panes/dashboard/token`)
    const pane = await shell(setup, paneUrl)

    const fromPane = await post(setup, pane.boot!.endpoints.modelContext, { content: [] })
    const malformed = await post(setup, endpoints.modelContext, { structuredContent: "x" })

    expect(fromPane).toEqual({
      status: 409,
      body: { error: "A pane has no chat to give context to" }
    })
    expect(malformed.status).toBe(400)
  })
})

describe("plugin app display query", () => {
  it("offers the app the modes the native host lists", async () => {
    const setup = await secured()
    const { viewId } = await openView(setup)
    const url = await launch(setup, `/v1/plugins/apps/${viewId}/token`)

    const pip = await shell(setup, `${url}&displayMode=pip&modes=inline,%20pip,bogus`)
    const plain = await shell(setup, `${url}&displayMode=sideways`)

    expect(pip.boot?.hostContext).toMatchObject({
      displayMode: "pip",
      availableDisplayModes: ["pip", "inline"]
    })
    expect(plain.boot?.hostContext).toMatchObject({
      displayMode: "inline",
      availableDisplayModes: ["inline"]
    })
  })
})
