import { describe, expect, it } from "vitest"

import {
  capturedView,
  launch,
  post,
  secured,
  shell,
  type Secured
} from "../plugins/apps/plugin-app-route-support.js"
import { jsonRequest, makeServices, run, startWithApp, waitFor } from "../test-support.js"
import { field, itemsOf } from "./response-test-support.js"

const viewIn = async (setup: Secured) => {
  const viewId = await capturedView(setup)
  return { viewId, sessionId: (await setup.services.mcp.appView(viewId))!.sessionId }
}

const send = (setup: Secured, sessionId: string, body: Record<string, unknown>) =>
  jsonRequest(setup.server, `/v1/sessions/${sessionId}/prompt`, {
    method: "POST",
    headers: setup.authorized,
    body: JSON.stringify(body)
  })

describe("app-sent chat messages", () => {
  it("sends them as normal user messages labelled with the app that sent them", async () => {
    const setup = await secured()
    const { viewId, sessionId } = await viewIn(setup)
    const { boot } = await shell(setup, await launch(setup, `/v1/plugins/apps/${viewId}/token`))
    await post(setup, boot!.endpoints.modelContext, { structuredContent: { selected: 2 } })

    const sent = await send(setup, sessionId, {
      text: "Silence the worst one",
      attribution: { kind: "app", viewId, plugin: "Someone else" }
    })
    await waitFor(() => setup.agents.prompts.length === 1)
    const transcript = await jsonRequest(setup.server, `/v1/sessions/${sessionId}/transcript`, {
      headers: setup.authorized
    })

    expect(sent.status).toBe(202)
    expect(setup.agents.prompts[0]?.[1]).toBe(
      `<codevisor-app-context plugin="Grafana" tool="show_alerts" viewId="${viewId}">\n{"selected":2}\n</codevisor-app-context>\n\nSilence the worst one`
    )
    expect(
      itemsOf(field(transcript.body, "items")).find((item) => field(item, "role") === "user")
    ).toMatchObject({
      text: "Silence the worst one",
      attribution: { kind: "app", viewId, plugin: "Grafana" }
    })
  })

  it("refuses attributions to views that aren't this chat's", async () => {
    const setup = await secured()
    const mine = await viewIn(setup)
    const theirs = await viewIn(setup)

    const unknown = await send(setup, mine.sessionId, {
      text: "Hi",
      attribution: {
        kind: "app",
        viewId: "0b9a8f8e-5d1c-4f43-9f53-3e1c2c7f2a10",
        plugin: "Grafana"
      }
    })
    const foreign = await send(setup, mine.sessionId, {
      text: "Hi",
      attribution: { kind: "app", viewId: theirs.viewId, plugin: "Grafana" }
    })
    const malformed = await send(setup, mine.sessionId, {
      text: "Hi",
      attribution: { kind: "bot", viewId: theirs.viewId }
    })

    expect(unknown).toEqual({
      status: 400,
      body: { error: "That app view doesn't belong to this chat" }
    })
    expect(foreign.status).toBe(400)
    expect(malformed.status).toBe(400)
    expect(setup.agents.prompts).toEqual([])
  })

  it("refuses attributions when this server has no plugins", async () => {
    const { services } = await makeServices()
    const { mcp: _mcp, ...withoutMcp } = services
    const server = await startWithApp(withoutMcp)
    const project = await run(services.db.createProject({ folderPath: "/tmp/prompt-attribution" }))
    const session = await run(
      services.db.createSession({ harnessId: "codex", projectId: project.id })
    )

    const response = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({
        text: "Hi",
        attribution: { kind: "app", viewId: "view-1", plugin: "Grafana" }
      })
    })

    expect(response.status).toBe(400)
  })
})
