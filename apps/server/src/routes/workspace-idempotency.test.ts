import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs } from "../test-support.js"

/// Clients send workspace and pane changes from an outbox and retry them until
/// the server answers. A retry that arrives after the change already happened
/// -- or after another device removed the row -- must get its real outcome,
/// never a 500 that would keep it retrying forever.
const setUp = async () => {
  const started = await start()
  const folder = mkdtempSync(join(tmpdir(), "codevisor-idempotency-"))
  tempDirs.push(folder)
  const project = (
    await jsonRequest(started.server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder }),
      method: "POST"
    })
  ).body as { readonly id: string }
  await jsonRequest(started.server, "/v1/workspaces/ws-1", {
    body: JSON.stringify({ projectId: project.id, name: "One", hasCustomName: false }),
    method: "PUT"
  })
  return { ...started, folder, project }
}

describe("workspace route idempotency", () => {
  it("answers a repeated workspace delete as already done", async () => {
    const { server, services } = await setUp()
    expect((await jsonRequest(server, "/v1/workspaces/ws-1", { method: "DELETE" })).status).toBe(
      204
    )
    expect((await jsonRequest(server, "/v1/workspaces/ws-1", { method: "DELETE" })).status).toBe(
      204
    )
    expect(await run(services.db.listWorkspaces)).toEqual([])
  })

  it("rejects an edit to a workspace that no longer exists with 404", async () => {
    const { server } = await setUp()
    const response = await jsonRequest(server, "/v1/workspaces/missing", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(response.status).toBe(404)
  })

  it("treats pane changes in a missing workspace as 404, and closing one as done", async () => {
    const { server } = await setUp()
    const upsert = await jsonRequest(server, "/v1/workspaces/missing/panes/pane-1", {
      body: JSON.stringify({ providerId: "codevisor", paneType: "terminal", title: "Terminal" }),
      method: "PUT"
    })
    expect(upsert.status).toBe(404)
    const close = await jsonRequest(server, "/v1/workspaces/missing/panes/pane-1/close", {
      method: "POST"
    })
    expect(close.status).toBe(200)
    const remove = await jsonRequest(server, "/v1/workspaces/missing/panes/pane-1", {
      method: "DELETE"
    })
    expect(remove.status).toBe(200)
  })

  it("rejects a patch to a pane that no longer exists with 404", async () => {
    const { server } = await setUp()
    const response = await jsonRequest(server, "/v1/workspaces/ws-1/panes/gone", {
      body: JSON.stringify({ title: "Renamed" }),
      method: "PATCH"
    })
    expect(response.status).toBe(404)
  })

  it("creates a chat's workspace once, however many times opening it is retried", async () => {
    // A new workspace lives only on the device until its first chat opens;
    // opening that chat is what creates it on the server, so the open has to
    // be safe to resend.
    const { server, services, project } = await setUp()
    const open = () =>
      jsonRequest(server, "/v1/sessions/chat-1/open", {
        body: JSON.stringify({
          session: {
            harnessId: "codex",
            id: "chat-1",
            projectId: project.id,
            workspaceId: "draft-ws",
            deferAgentSession: true
          }
        }),
        method: "POST"
      })
    expect((await open()).status).toBe(200)
    expect((await open()).status).toBe(200)
    const workspaces = await run(services.db.listWorkspaces)
    expect(workspaces.filter((workspace) => workspace.id === "draft-ws")).toHaveLength(1)
    const panes = await run(services.db.listWorkspacePanes)
    expect(panes.filter((pane) => pane.resourceId === "chat-1")).toHaveLength(1)
  })
})
