import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, initialWorkspacePosition, Workspace, WorkspaceSnapshot } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, readSseEvents, run, start, tempDirs, listEvents } from "../test-support.js"
import { idOf } from "./response-test-support.js"

const decodeWorkspace = decode(Workspace)
const decodeWorkspaces = decode(Schema.Array(Workspace))

describe("workspace ordering over HTTP", () => {
  it("publishes moves, applies the latest one even from a stale revision, and snapshots the same order", async () => {
    const { server, services } = await start()
    const folder = mkdtempSync(join(tmpdir(), "workspace-order-http-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const put = {
      method: "PUT",
      body: JSON.stringify({ projectId: project.id, name: "A", hasCustomName: false })
    }
    const first = decodeWorkspace((await jsonRequest(server, "/v1/workspaces/first", put)).body)
    await jsonRequest(server, "/v1/workspaces/second", put)
    const frontier = initialWorkspacePosition(2_000_000_000_000, "third")
    const third = decodeWorkspace(
      (
        await jsonRequest(server, "/v1/workspaces/third", {
          method: "PUT",
          body: JSON.stringify({
            projectId: project.id,
            name: "New",
            hasCustomName: false,
            sidebarOrderHead: frontier
          })
        })
      ).body
    )
    expect(third.sidebarPosition! < frontier).toBe(true)
    const replay = listEvents(services)
    const live = readSseEvents(server, 1, replay.at(-1)?.id ?? 0)
    const position = initialWorkspacePosition(100, first.id)
    const moved = await jsonRequest(server, "/v1/workspaces/first", {
      method: "PATCH",
      body: JSON.stringify({ sidebarOrder: { position, expectedRevision: 1 } })
    })
    expect(moved.status).toBe(200)
    expect(moved.body).toMatchObject({ sidebarPosition: position, sidebarOrderRevision: 2 })
    expect(await live).toEqual([
      expect.objectContaining({
        kind: "workspace.updated",
        payload: expect.objectContaining({ sidebarPosition: position, sidebarOrderRevision: 2 })
      })
    ])
    const latest = initialWorkspacePosition(50, first.id)
    const stale = await jsonRequest(server, "/v1/workspaces/first", {
      method: "PATCH",
      body: JSON.stringify({ sidebarOrder: { position: latest, expectedRevision: 1 } })
    })
    expect(stale.status).toBe(200)
    expect(stale.body).toMatchObject({ sidebarPosition: latest, sidebarOrderRevision: 3 })
    const snapshot = decode(WorkspaceSnapshot)(
      (await jsonRequest(server, "/v1/workspace-snapshot")).body
    )
    expect(snapshot.workspaces.map((row) => row.id)).toEqual(["third", "second", "first"])
    const invalid = await jsonRequest(server, "/v1/workspaces/first", {
      method: "PATCH",
      body: JSON.stringify({ sidebarOrder: { position: "NaN", expectedRevision: 2 } })
    })
    expect(invalid.status).toBe(400)
    const session = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({
        projectId: project.id,
        harnessId: "codex",
        deferAgentSession: true,
        workspaceId: "fourth",
        sidebarOrderHead: third.sidebarPosition
      })
    })
    expect(session.status).toBe(201)
    const rows = decodeWorkspaces((await jsonRequest(server, "/v1/workspaces")).body)
    expect(rows[0]?.id).toBe("fourth")
    expect(rows[0]!.sidebarPosition! < third.sidebarPosition!).toBe(true)
    const movedSession = await jsonRequest(server, `/v1/sessions/${idOf(session.body)}`, {
      method: "PATCH",
      body: JSON.stringify({ workspaceId: "fifth", sidebarOrderHead: rows[0]?.sidebarPosition })
    })
    expect(movedSession.status).toBe(200)
    expect(decodeWorkspaces((await jsonRequest(server, "/v1/workspaces")).body)[0]?.id).toBe(
      "fifth"
    )
  })
})
