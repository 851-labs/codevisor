import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { jsonRequest, readSseEvents, run, start, tempDirs } from "../test-support.js"

describe("workspace routes", () => {
  it("atomically promotes a new-tab pane into its deferred chat", async () => {
    const { server, services } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-server-pane-promotion-"))
    tempDirs.push(root)
    const projectFolder = join(root, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, "/v1/workspaces/main", {
      body: JSON.stringify({ projectId: project.id, name: "Main", hasCustomName: false }),
      method: "PUT"
    })
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/missing/panes/stable-pane/promote-chat", {
          body: JSON.stringify({
            session: { projectId: project.id, harnessId: "codex" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/main/panes/missing/promote-chat", {
          body: JSON.stringify({
            session: { projectId: project.id, harnessId: "codex" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
    const placeholder = await jsonRequest(server, "/v1/workspaces/main/panes/stable-pane", {
      body: JSON.stringify({
        providerId: "codevisor",
        paneType: "new-tab",
        title: "New tab"
      }),
      method: "PUT"
    })
    expect(placeholder.body).toMatchObject({ id: "stable-pane", revision: 1 })
    const otherFolder = join(root, "other")
    mkdirSync(otherFolder)
    const otherProject = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: otherFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/main/panes/stable-pane/promote-chat", {
          body: JSON.stringify({
            session: { projectId: otherProject.id, harnessId: "codex" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(409)

    const replay = await run(services.db.listEvents(0))
    const live = readSseEvents(server, 2, replay.at(-1)?.id ?? 0)
    const promoted = await jsonRequest(
      server,
      "/v1/workspaces/main/panes/stable-pane/promote-chat",
      {
        body: JSON.stringify({
          session: {
            id: "new-chat",
            projectId: project.id,
            harnessId: "codex",
            deferAgentSession: true,
            title: "New Chat"
          },
          title: "New Chat"
        }),
        method: "POST"
      }
    )

    expect(promoted).toEqual({
      status: 201,
      body: {
        pane: expect.objectContaining({
          id: "stable-pane",
          paneType: "chat",
          resourceId: "new-chat",
          revision: 2
        }),
        session: expect.objectContaining({ id: "new-chat", workspaceId: "main" })
      }
    })
    expect((await jsonRequest(server, "/v1/workspace-panes")).body).toEqual([
      expect.objectContaining({ id: "stable-pane", paneType: "chat", resourceId: "new-chat" })
    ])
    expect(await live).toEqual([
      expect.objectContaining({
        kind: "session.created",
        subjectId: "new-chat",
        payload: expect.objectContaining({ workspaceId: "main" })
      }),
      expect.objectContaining({
        kind: "workspace.pane.updated",
        subjectId: "stable-pane",
        payload: expect.objectContaining({ paneType: "chat", revision: 2 })
      })
    ])

    const retried = await jsonRequest(
      server,
      "/v1/workspaces/main/panes/stable-pane/promote-chat",
      {
        body: JSON.stringify({
          session: { id: "new-chat", projectId: project.id, harnessId: "codex" }
        }),
        method: "POST"
      }
    )
    expect(retried).toEqual({
      status: 200,
      body: {
        pane: expect.objectContaining({ title: "New Chat", revision: 3 }),
        session: expect.objectContaining({ id: "new-chat", workspaceId: "main" })
      }
    })

    await jsonRequest(server, "/v1/workspaces/main/panes/empty-title-pane", {
      body: JSON.stringify({ providerId: "codevisor", paneType: "new-tab", title: "New tab" }),
      method: "PUT"
    })
    const emptyTitle = await jsonRequest(
      server,
      "/v1/workspaces/main/panes/empty-title-pane/promote-chat",
      {
        body: JSON.stringify({
          session: {
            id: "empty-title-chat",
            projectId: project.id,
            harnessId: "codex",
            deferAgentSession: true,
            title: ""
          }
        }),
        method: "POST"
      }
    )
    expect(emptyTitle.body).toMatchObject({
      pane: { id: "empty-title-pane", title: "New Chat", resourceId: "empty-title-chat" }
    })
  })

  it("serves and publishes server-owned workspace panes", async () => {
    const { server, services } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-server-workspace-panes-"))
    tempDirs.push(root)
    const projectFolder = join(root, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, "/v1/workspaces/workspace-panes", {
      body: JSON.stringify({ projectId: project.id, name: "Main", hasCustomName: false }),
      method: "PUT"
    })

    expect(await jsonRequest(server, "/v1/workspace-panes")).toEqual({ status: 200, body: [] })
    const replay = await run(services.db.listEvents(0))
    const live = readSseEvents(server, 1, replay.at(-1)?.id ?? 0)
    const created = await jsonRequest(server, "/v1/workspaces/workspace-panes/panes/pane-1", {
      body: JSON.stringify({
        id: "pane-1",
        providerId: "codevisor",
        paneType: "new-tab",
        title: "New tab"
      }),
      method: "PUT"
    })
    expect(created).toEqual({
      status: 200,
      body: expect.objectContaining({
        id: "pane-1",
        workspaceId: "workspace-panes",
        providerId: "codevisor",
        paneType: "new-tab"
      })
    })
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/workspace-panes/panes/pane-1", {
          body: JSON.stringify({
            id: "other-pane",
            providerId: "codevisor",
            paneType: "new-tab",
            title: "Wrong id"
          }),
          method: "PUT"
        })
      ).status
    ).toBe(400)
    expect(await live).toEqual([
      expect.objectContaining({
        kind: "workspace.pane.updated",
        subjectId: "pane-1",
        payload: expect.objectContaining({ workspaceId: "workspace-panes" })
      })
    ])

    const converted = await jsonRequest(server, "/v1/workspaces/workspace-panes/panes/pane-1", {
      body: JSON.stringify({ paneType: "terminal", resourceKind: "terminal", resourceId: "pty-1" }),
      method: "PATCH"
    })
    expect(converted.body).toMatchObject({
      id: "pane-1",
      paneType: "terminal",
      resourceKind: "terminal",
      resourceId: "pty-1"
    })
    expect((await jsonRequest(server, "/v1/workspace-panes")).body).toEqual([
      expect.objectContaining({ id: "pane-1", paneType: "terminal" })
    ])
    expect(await jsonRequest(server, "/v1/workspace-snapshot")).toEqual({
      status: 200,
      body: {
        workspaces: [expect.objectContaining({ id: "workspace-panes" })],
        panes: [expect.objectContaining({ id: "pane-1", paneType: "terminal" })]
      }
    })

    const finalClose = await jsonRequest(
      server,
      "/v1/workspaces/workspace-panes/panes/pane-1/close",
      { method: "POST" }
    )
    expect(finalClose).toEqual({
      status: 200,
      body: {
        pane: expect.objectContaining({
          id: "pane-1",
          paneType: "new-tab",
          title: "New tab",
          revision: 3
        })
      }
    })
    // Retrying a final close does not advance the pane revision.
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/workspace-panes/panes/pane-1/close", {
          method: "POST"
        })
      ).body
    ).toEqual(finalClose.body)

    await jsonRequest(server, "/v1/workspaces/workspace-panes/panes/pane-2", {
      body: JSON.stringify({ providerId: "codevisor", paneType: "new-tab", title: "New tab" }),
      method: "PUT"
    })
    expect(
      await jsonRequest(server, "/v1/workspaces/workspace-panes/panes/pane-2/close", {
        method: "POST"
      })
    ).toEqual({ status: 200, body: {} })
    expect(
      await jsonRequest(server, "/v1/workspaces/workspace-panes/panes/pane-2", {
        method: "DELETE"
      })
    ).toEqual({ status: 200, body: {} })
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/workspace-panes/panes/pane-1", {
          method: "DELETE"
        })
      ).body
    ).toEqual({
      pane: expect.objectContaining({ id: "pane-1", paneType: "new-tab", revision: 3 })
    })
    expect((await jsonRequest(server, "/v1/workspace-panes")).body).toEqual([
      expect.objectContaining({ id: "pane-1", paneType: "new-tab" })
    ])
  })

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
})
