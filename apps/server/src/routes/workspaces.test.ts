import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { jsonRequest, readSseEvents, run, start, tempDirs } from "../test-support.js"

describe("workspace routes", () => {
  it("serves pane workspaces with idempotent PUTs and change events", async () => {
    const { server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-workspaces-"))
    tempDirs.push(workspaceRoot)
    const projectFolder = join(workspaceRoot, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }

    expect(await jsonRequest(server, "/v1/workspaces")).toEqual({ status: 200, body: [] })

    const put = await jsonRequest(server, "/v1/workspaces/workspace-1", {
      body: JSON.stringify({ projectId: project.id, name: "Main", hasCustomName: false }),
      method: "PUT"
    })
    expect(put.status).toBe(200)
    expect(put.body).toMatchObject({
      id: "workspace-1",
      serverId: "server-a",
      projectId: project.id,
      name: "Main",
      hasCustomName: false,
      isArchived: false
    })

    // A body id matching the path is allowed; the second PUT updates in place
    // and publishes the same workspace.updated kind as the create.
    const replayBeforePut = await run(services.db.listEvents(0))
    const livePut = readSseEvents(server, 1, replayBeforePut.at(-1)?.id ?? 0)
    const renamed = await jsonRequest(server, "/v1/workspaces/workspace-1", {
      body: JSON.stringify({
        id: "workspace-1",
        projectId: project.id,
        name: "Renamed",
        hasCustomName: true,
        symbolName: "hammer",
        rootDirectory: projectFolder,
        isArchived: false
      }),
      method: "PUT"
    })
    expect(renamed.status).toBe(200)
    expect(renamed.body).toMatchObject({
      name: "Renamed",
      hasCustomName: true,
      symbolName: "hammer",
      rootDirectory: projectFolder
    })
    expect((renamed.body as { readonly updatedAt?: string }).updatedAt).toBeDefined()
    expect(await livePut).toEqual([
      expect.objectContaining({
        kind: "workspace.updated",
        subjectId: "workspace-1",
        payload: expect.objectContaining({ name: "Renamed" })
      })
    ])
    expect((await jsonRequest(server, "/v1/workspaces")).body).toMatchObject([
      { id: "workspace-1", name: "Renamed" }
    ])

    // Sessions can be created directly into a workspace.
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: project.id,
          harnessId: "codex",
          workspaceId: "workspace-1"
        }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly workspaceId?: string }
    expect(session.workspaceId).toBe("workspace-1")

    // A body id that disagrees with the path is rejected before any write.
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/workspace-1", {
          body: JSON.stringify({
            id: "other",
            projectId: project.id,
            name: "Nope",
            hasCustomName: false
          }),
          method: "PUT"
        })
      ).status
    ).toBe(400)

    // Missing rows surface exactly like the project routes' database errors.
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/workspace-2", {
          body: JSON.stringify({ projectId: "missing", name: "Nope", hasCustomName: false }),
          method: "PUT"
        })
      ).status
    ).toBe(500)
    expect((await jsonRequest(server, "/v1/workspaces/missing", { method: "DELETE" })).status).toBe(
      500
    )

    // A workspace that still owns a session is protected by its foreign key.
    expect(
      (await jsonRequest(server, "/v1/workspaces/workspace-1", { method: "DELETE" })).status
    ).toBe(500)
    await jsonRequest(server, `/v1/sessions/${session.id}`, { method: "DELETE" })

    const replayBeforeDelete = await run(services.db.listEvents(0))
    const liveDelete = readSseEvents(server, 1, replayBeforeDelete.at(-1)?.id ?? 0)
    expect(
      (await jsonRequest(server, "/v1/workspaces/workspace-1", { method: "DELETE" })).status
    ).toBe(204)
    expect(await liveDelete).toEqual([
      expect.objectContaining({
        kind: "workspace.deleted",
        subjectId: "workspace-1",
        payload: { id: "workspace-1" }
      })
    ])
    expect(await run(services.db.listEvents(0))).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "workspace.updated",
          subjectId: "workspace-1",
          payload: expect.objectContaining({ name: "Main" })
        }),
        expect.objectContaining({ kind: "workspace.deleted", subjectId: "workspace-1" })
      ])
    )

    // Unmatched workspace methods fall through to the 404 handler.
    expect((await jsonRequest(server, "/v1/workspaces", { method: "POST" })).status).toBe(404)
  })

  it("materializes native workspace identities when sessions assign them", async () => {
    const { server, services } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-server-native-workspaces-"))
    tempDirs.push(root)
    const projectFolder = join(root, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly name: string }

    const created = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        id: "native-chat",
        projectId: project.id,
        harnessId: "codex",
        workspaceId: "native-workspace"
      }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    expect(created.body).toMatchObject({
      id: "native-chat",
      workspaceId: "native-workspace"
    })

    const detached = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "detached-chat",
          projectId: project.id,
          harnessId: "codex"
        }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const assigned = await jsonRequest(server, `/v1/sessions/${detached.id}`, {
      body: JSON.stringify({ workspaceId: "patched-workspace" }),
      method: "PATCH"
    })
    expect(assigned.status).toBe(200)
    expect(assigned.body).toMatchObject({ workspaceId: "patched-workspace" })

    const otherProjectFolder = join(root, "other-project")
    mkdirSync(otherProjectFolder)
    const otherProject = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: otherProjectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    expect(
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "conflicting-workspace-chat",
          projectId: otherProject.id,
          harnessId: "codex",
          workspaceId: "native-workspace"
        }),
        method: "POST"
      })
    ).toEqual({
      status: 409,
      body: {
        error: `Workspace native-workspace belongs to project ${project.id}, not ${otherProject.id}`
      }
    })

    expect((await jsonRequest(server, "/v1/workspaces")).body).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: "native-workspace",
          projectId: project.id,
          name: project.name,
          rootDirectory: projectFolder
        }),
        expect.objectContaining({
          id: "patched-workspace",
          projectId: project.id,
          name: project.name,
          rootDirectory: projectFolder
        })
      ])
    )
    expect(await run(services.db.listEvents(0))).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "workspace.updated", subjectId: "native-workspace" }),
        expect.objectContaining({ kind: "workspace.updated", subjectId: "patched-workspace" })
      ])
    )
  })
})
