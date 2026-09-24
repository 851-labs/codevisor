import { describe, expect, it } from "vitest"

import { jsonRequest, readSseEvents, run } from "../test-support.js"
import { setUpWorkspace } from "./session-test-support.js"

describe("shared names", () => {
  it("persists workspace and chat renames and broadcasts them to both clients", async () => {
    const { server, services, workspace: project } = await setUpWorkspace()
    const path = "/v1/workspaces/shared-workspace"
    expect(
      (
        await jsonRequest(server, path, {
          method: "PUT",
          body: JSON.stringify({ projectId: project.id, name: "Original", hasCustomName: false })
        })
      ).status
    ).toBe(200)
    const created = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({
        projectId: project.id,
        workspaceId: "shared-workspace",
        harnessId: "codex",
        title: "Original chat"
      })
    })
    expect(created.status).toBe(201)
    const chat = created.body as { id: string }
    const cursor = (await run(services.db.listEvents(0))).at(-1)?.id ?? 0
    const readers = [readSseEvents(server, 2, cursor), readSseEvents(server, 2, cursor)]
    expect(
      (
        await jsonRequest(server, path, {
          method: "PATCH",
          body: JSON.stringify({ name: "Shared workspace", hasCustomName: true })
        })
      ).body
    ).toMatchObject({ name: "Shared workspace", hasCustomName: true, isArchived: false })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${chat.id}`, {
          method: "PATCH",
          body: JSON.stringify({ title: "Shared chat", titleIntent: "rename" })
        })
      ).body
    ).toMatchObject({ title: "Shared chat", workspaceId: "shared-workspace" })
    const expected = [
      expect.objectContaining({
        kind: "workspace.updated",
        subjectId: "shared-workspace",
        payload: expect.objectContaining({ name: "Shared workspace", hasCustomName: true })
      }),
      expect.objectContaining({
        kind: "session.updated",
        subjectId: chat.id,
        payload: expect.objectContaining({ title: "Shared chat" })
      })
    ]
    for (const events of await Promise.all(readers)) expect(events).toEqual(expected)
    // A client reconnecting later gets the same names from its snapshot.
    expect((await jsonRequest(server, "/v1/workspaces")).body).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: "shared-workspace", name: "Shared workspace" })
      ])
    )
    expect((await jsonRequest(server, "/v1/sessions")).body).toEqual(
      expect.arrayContaining([expect.objectContaining({ id: chat.id, title: "Shared chat" })])
    )
  })
})
