import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs } from "../test-support.js"

describe("workspace create route", () => {
  it("creates a workspace around its first chat atomically", async () => {
    const { server, services } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-server-workspace-create-"))
    tempDirs.push(root)
    const projectFolder = join(root, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const before = await run(services.db.latestEventCursor)

    expect(
      (
        await jsonRequest(server, "/v1/workspaces", {
          body: JSON.stringify({
            workspace: { projectId: project.id, name: "Main", hasCustomName: false },
            session: { projectId: project.id, harnessId: "codex" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(400)

    const created = await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({
        workspace: { id: "ws-atomic", projectId: project.id, name: "Main", hasCustomName: false },
        session: { id: "chat-atomic", projectId: project.id, harnessId: "codex", title: "Hello" }
      }),
      method: "POST"
    })
    expect(created).toEqual({
      status: 201,
      body: {
        workspace: expect.objectContaining({ id: "ws-atomic", projectId: project.id }),
        session: expect.objectContaining({ id: "chat-atomic", workspaceId: "ws-atomic" }),
        pane: expect.objectContaining({
          id: "chat-atomic",
          workspaceId: "ws-atomic",
          paneType: "chat",
          resourceId: "chat-atomic"
        })
      }
    })
    expect(await jsonRequest(server, "/v1/workspace-snapshot")).toEqual({
      status: 200,
      body: {
        workspaces: [expect.objectContaining({ id: "ws-atomic" })],
        panes: [expect.objectContaining({ id: "chat-atomic" })]
      }
    })
    // One navigation delta carries workspace, session and pane together.
    const batch = await run(services.db.readSyncBatch(before))
    const deltas = batch.events.filter((event) => event.kind === "navigation.changed")
    expect(deltas).toHaveLength(1)
    expect(deltas[0]?.payload).toMatchObject({
      workspaces: [expect.objectContaining({ id: "ws-atomic" })],
      sessions: [expect.objectContaining({ id: "chat-atomic" })],
      panes: [expect.objectContaining({ id: "chat-atomic" })]
    })

    // Retrying converges (200) instead of minting a second session, and pane
    // options apply to the retried pane.
    const retried = await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({
        workspace: { id: "ws-atomic", projectId: project.id, name: "Main", hasCustomName: false },
        session: { id: "chat-atomic", projectId: project.id, harnessId: "codex", title: "Hello" },
        pane: { title: "Renamed" }
      }),
      method: "POST"
    })
    expect(retried).toEqual({
      status: 200,
      body: expect.objectContaining({ pane: expect.objectContaining({ title: "Renamed" }) })
    })
    expect(((await jsonRequest(server, "/v1/sessions")).body as Array<unknown>).length).toBe(1)

    // Omitting the session id lets the server mint one; the pane follows it.
    const minted = await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({
        workspace: { id: "ws-minted", projectId: project.id, name: "Minted", hasCustomName: false },
        session: { projectId: project.id, harnessId: "codex", deferAgentSession: true }
      }),
      method: "POST"
    })
    expect(minted.status).toBe(201)
    const mintedBody = minted.body as {
      readonly session: { readonly id: string }
      readonly pane: { readonly id: string }
    }
    expect(mintedBody.pane.id).toBe(mintedBody.session.id)

    // Assigning an EXISTING chat to an EXISTING workspace keeps the
    // workspace's record untouched and only adds membership and the pane.
    const loose = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: project.id,
          harnessId: "codex",
          deferAgentSession: true
        }),
        method: "POST"
      })
    ).body as { readonly id: string }
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${loose.id}`, {
          body: JSON.stringify({ workspaceId: "ws-atomic" }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ workspaceId: "ws-atomic" })
    expect(
      (
        (await jsonRequest(server, "/v1/workspace-panes")).body as Array<{ resourceId?: string }>
      ).some((pane) => pane.resourceId === loose.id)
    ).toBe(true)

    // A workspace and chat from different projects never pair.
    const otherFolder = join(root, "other")
    mkdirSync(otherFolder)
    const other = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: otherFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    expect(
      (
        await jsonRequest(server, "/v1/workspaces", {
          body: JSON.stringify({
            workspace: { id: "ws-other", projectId: other.id, name: "Other", hasCustomName: false },
            session: { projectId: project.id, harnessId: "codex" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(409)
  })
})
