import { decode } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, listEvents, waitFor } from "../test-support.js"
import { field } from "./response-test-support.js"
import { CreatedSession, setUpWorkspace } from "./session-test-support.js"

describe("session titles", () => {
  it("replaces the first-send fallback and protects an explicit rename from later harness updates", async () => {
    const { server, agents, workspace, services } = await setUpWorkspace()
    const created = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "New Chat" })
    })
    expect(created.status).toBe(201)
    const session = decode(CreatedSession)(created.body)
    const patch = async (title: string, titleIntent: string) =>
      jsonRequest(server, `/v1/sessions/${session.id}`, {
        method: "PATCH",
        body: JSON.stringify({ title, titleIntent })
      })
    const harnessTitle = async (title: string) =>
      agents.emit(session.agentSessionId, {
        kind: "session.updated",
        subjectId: session.agentSessionId,
        payload: { sessionUpdate: "session_info_update", title }
      })
    expect((await patch("Please fix the login form", "fallback")).status).toBe(200)
    await harnessTitle("Fix login validation")
    expect((await run(services.db.getSessionSummary(session.id))).title).toBe(
      "Fix login validation"
    )
    await patch("Please fix the login form", "fallback")
    expect((await run(services.db.getSessionSummary(session.id))).title).toBe(
      "Fix login validation"
    )
    await patch("Fix login validation", "rename")
    await harnessTitle("Replace login title")
    expect((await run(services.db.getSessionSummary(session.id))).title).toBe(
      "Fix login validation"
    )
    const published = listEvents(services)
    expect(
      published.some(
        (event) =>
          event.kind === "session.updated" &&
          field(event.payload, "title") === "Fix login validation"
      )
    ).toBe(true)
  })

  it("never titles a chat after the hidden prompt that resumes it after an update", async () => {
    const { server, agents, workspace, services } = await setUpWorkspace()
    const created = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "New Chat" })
    })
    const session = decode(CreatedSession)(created.body)
    const delivered = (sent: number) => waitFor(() => agents.prompts.length > sent)
    const sendPrompt = async (text: string) => {
      const sent = agents.prompts.length
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        method: "POST",
        body: JSON.stringify({ text })
      })
      await delivered(sent)
    }
    const sendHiddenPrompt = async (text: string) => {
      const sent = agents.prompts.length
      const item = await run(
        services.db.createPromptQueueItem(session.id, text, [], undefined, undefined, "system")
      )
      await jsonRequest(server, `/v1/sessions/${session.id}/queue/${item.id}/send-now`, {
        method: "POST"
      })
      await delivered(sent)
    }
    const harnessTitle = (title: string) =>
      agents.emit(session.agentSessionId, {
        kind: "session.updated",
        subjectId: session.agentSessionId,
        payload: { sessionUpdate: "session_info_update", title }
      })
    const title = async () => (await run(services.db.getSessionSummary(session.id))).title

    await sendPrompt("Count to 120")
    await harnessTitle("Count to 120")
    expect(await title()).toBe("Count to 120")

    await sendHiddenPrompt("continue")
    await harnessTitle("continue")
    expect(await title()).toBe("Count to 120")

    await harnessTitle("Counting to 120")
    expect(await title()).toBe("Counting to 120")
  })
})
