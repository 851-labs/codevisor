import { NavigationSnapshot } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, readSseEvents, listEvents } from "../test-support.js"
import { idOf } from "./response-test-support.js"
import { setUpWorkspace } from "./session-test-support.js"

const workspacePath = "/v1/workspaces/shared-workspace"

const setUpSharedName = async () => {
  const setup = await setUpWorkspace()
  const { server, workspace: project } = setup
  await jsonRequest(server, workspacePath, {
    method: "PUT",
    body: JSON.stringify({ projectId: project.id, name: "Original", hasCustomName: false })
  })
  const chat = async (title: string) =>
    idOf(
      (
        await jsonRequest(server, "/v1/sessions", {
          method: "POST",
          body: JSON.stringify({
            projectId: project.id,
            workspaceId: "shared-workspace",
            harnessId: "codex",
            title
          })
        })
      ).body
    )
  const main = await chat("Original chat")
  await chat("Side chat")
  return { ...setup, main }
}

const navigationNames = async (
  server: Parameters<typeof jsonRequest>[0]
): Promise<{ readonly workspace: string | undefined; readonly titles: ReadonlyArray<string> }> => {
  const snapshot = Schema.decodeUnknownSync(NavigationSnapshot)(
    (await jsonRequest(server, "/v1/navigation")).body
  )
  return {
    workspace: snapshot.workspaces.find(({ id }) => id === "shared-workspace")?.name,
    titles: snapshot.sessions.map(({ title }) => title).toSorted()
  }
}

describe("shared names", () => {
  it("gives the main chat a workspace's new name and broadcasts the rename", async () => {
    const { server, services } = await setUpSharedName()
    const cursor = listEvents(services).at(-1)?.id ?? 0
    const readers = [readSseEvents(server, 1, cursor), readSseEvents(server, 1, cursor)]

    const renamed = await jsonRequest(server, workspacePath, {
      method: "PATCH",
      body: JSON.stringify({ name: "macro", hasCustomName: true })
    })

    expect(renamed.body).toMatchObject({ name: "macro", hasCustomName: true, isArchived: false })
    for (const events of await Promise.all(readers)) {
      expect(events).toEqual([
        expect.objectContaining({
          kind: "workspace.updated",
          subjectId: "shared-workspace",
          payload: expect.objectContaining({ name: "macro", hasCustomName: true })
        })
      ])
    }
    expect(await navigationNames(server)).toEqual({
      workspace: "macro",
      titles: ["Side chat", "macro"]
    })
  })

  it("gives the workspace its main chat's new title", async () => {
    const { server, main } = await setUpSharedName()
    await jsonRequest(server, workspacePath, {
      method: "PATCH",
      body: JSON.stringify({ name: "macro", hasCustomName: true })
    })

    const renamed = await jsonRequest(server, `/v1/sessions/${main}`, {
      method: "PATCH",
      body: JSON.stringify({ title: "Lunch log", titleIntent: "rename" })
    })

    expect(renamed.body).toMatchObject({ title: "Lunch log", workspaceId: "shared-workspace" })
    expect(await navigationNames(server)).toEqual({
      workspace: "Lunch log",
      titles: ["Lunch log", "Side chat"]
    })
  })
})
