import { describe, expect, it } from "vitest"

import { jsonRequest, run } from "../test-support.js"
import { setUpWorkspace } from "./session-test-support.js"

describe("session titles", () => {
  it("replaces the first-send fallback and protects an explicit rename from later harness updates", async () => {
    const { server, agents, workspace, services } = await setUpWorkspace()
    const created = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "New Chat" })
    })
    expect(created.status).toBe(201)
    const session = created.body as { id: string; agentSessionId: string }
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
    // Accepting the existing text in Rename is still a user choice.
    await patch("Fix login validation", "rename")
    await harnessTitle("Replace login title")
    expect((await run(services.db.getSessionSummary(session.id))).title).toBe(
      "Fix login validation"
    )
    const published = await run(services.db.listEvents(0))
    expect(
      published.some(
        (event) =>
          event.kind === "session.updated" &&
          (event.payload as { title?: string }).title === "Fix login validation"
      )
    ).toBe(true)
  })
})
