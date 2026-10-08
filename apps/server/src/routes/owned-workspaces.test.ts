import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { SessionSummary, Workspace } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { jsonRequest, run, start, tempDirs } from "../test-support.js"
import { assertWorkspaceOwner } from "./workspace-ownership.js"

const cyclicWorkspace = (id: string, parentWorkspaceId: string): Workspace => ({
  id,
  serverId: "local",
  projectId: "project",
  name: id,
  hasCustomName: false,
  isArchived: false,
  createdAt: "2026-01-01T00:00:00.000Z",
  parentWorkspaceId
})

const fixture = async () => {
  const { server, services } = await start()
  const root = mkdtempSync(join(tmpdir(), "codevisor-server-owned-workspaces-"))
  tempDirs.push(root)
  const folderPath = join(root, "project")
  mkdirSync(folderPath)
  const project = (
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath }),
      method: "POST"
    })
  ).body as { readonly id: string }
  const createSession = async (body: Record<string, unknown>) => {
    const response = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ projectId: project.id, harnessId: "codex", ...body }),
      method: "POST"
    })
    expect(response.status).toBe(201)
    return response.body as SessionSummary
  }
  const workspaces = async () =>
    (
      (await jsonRequest(server, "/v1/workspace-snapshot")).body as {
        readonly workspaces: ReadonlyArray<Workspace>
      }
    ).workspaces
  const workspace = async (id: string) => (await workspaces()).find((w) => w.id === id)!
  const patch = (id: string, body: Record<string, unknown>) =>
    jsonRequest(server, `/v1/workspaces/${id}`, { body: JSON.stringify(body), method: "PATCH" })
  const parent = await createSession({ workspaceId: "ws-parent" })
  return { server, services, root, project, createSession, workspace, workspaces, patch, parent }
}

describe("owned workspaces", () => {
  it("places agent-created chats as a tab, an owned group, or a top-level workspace", async () => {
    const { createSession, workspace, workspaces, parent } = await fixture()

    const shared = await createSession({ parentSessionId: parent.id, workspacePlacement: "shared" })
    expect(shared.workspaceId).toBe("ws-parent")

    const owned = await createSession({ parentSessionId: parent.id, workspacePlacement: "owned" })
    expect(owned.workspaceId).not.toBe("ws-parent")
    expect(await workspace(owned.workspaceId!)).toMatchObject({
      parentWorkspaceId: "ws-parent",
      parentTabPosition: expect.any(String)
    })

    const independent = await createSession({
      parentSessionId: parent.id,
      workspacePlacement: "independent"
    })
    expect((await workspace(independent.workspaceId!)).parentWorkspaceId).toBeUndefined()

    // A placement without a parent chat makes a top-level workspace.
    const unparented = await createSession({ workspacePlacement: "owned" })
    expect((await workspace(unparented.workspaceId!)).parentWorkspaceId).toBeUndefined()

    // A chat whose parent has no workspace still lands somewhere visible.
    const orphan = await createSession({})
    const fallback = await createSession({
      parentSessionId: orphan.id,
      workspacePlacement: "shared"
    })
    expect((await workspaces()).some((w) => w.id === fallback.workspaceId)).toBe(true)
  })

  it("promotes and re-parents through PATCH and refuses impossible owners", async () => {
    const { createSession, workspace, patch, parent } = await fixture()
    const owned = await createSession({ parentSessionId: parent.id, workspacePlacement: "owned" })
    const child = owned.workspaceId!

    expect((await patch("ws-parent", { parentWorkspaceId: child })).status).toBe(409)
    expect((await patch(child, { parentWorkspaceId: "missing" })).status).toBe(409)

    expect((await patch(child, { parentWorkspaceId: null })).status).toBe(200)
    expect((await workspace(child)).parentWorkspaceId).toBeUndefined()

    expect(
      (await patch(child, { parentWorkspaceId: "ws-parent", groupCollapsed: true })).status
    ).toBe(200)
    expect(await workspace(child)).toMatchObject({
      parentWorkspaceId: "ws-parent",
      groupCollapsed: true
    })
  })

  it("refuses to create a workspace under a missing owner", async () => {
    const { server, project, createSession } = await fixture()
    const response = await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({
        workspace: {
          id: "ws-orphan",
          projectId: project.id,
          name: "Orphan",
          hasCustomName: false,
          parentWorkspaceId: "missing"
        },
        session: { projectId: project.id, harnessId: "codex" }
      }),
      method: "POST"
    })
    expect(response.status).toBe(409)
    // A session create naming the owner directly is checked the same way.
    const direct = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: project.id,
        harnessId: "codex",
        workspaceId: "ws-direct",
        parentWorkspaceId: "missing"
      }),
      method: "POST"
    })
    expect(direct.status).toBe(409)
    // Retrying the create of an existing workspace skips the owner check.
    expect(
      (await createSession({ workspaceId: "ws-parent", parentWorkspaceId: "missing" })).workspaceId
    ).toBe("ws-parent")
  })

  it("reorders tabs and owned tab groups together", async () => {
    const { server, createSession, workspace, parent } = await fixture()
    const owned = await createSession({ parentSessionId: parent.id, workspacePlacement: "owned" })
    const child = owned.workspaceId!
    const reordered = await jsonRequest(server, "/v1/workspaces/ws-parent/panes/reorder", {
      body: JSON.stringify({ paneIds: [child, parent.id] }),
      method: "POST"
    })
    expect(reordered.status).toBe(200)
    const chat = (reordered.body as ReadonlyArray<{ id: string; position: string }>).find(
      (pane) => pane.id === parent.id
    )!
    expect((await workspace(child)).parentTabPosition! < chat.position).toBe(true)
  })

  it("runs a shared chat in its parent's worktree unless it names one", async () => {
    const { services, root, project, createSession } = await fixture()
    vi.stubEnv("CODEVISOR_WORKTREES_ROOT", join(root, "worktrees"))
    const make = async (name: string) => {
      const worktree = await run(services.db.createWorktree(project.id, name, name))
      mkdirSync(worktree.path, { recursive: true })
      return worktree
    }
    const feature = await make("feature")
    const other = await make("other")
    const parent = await createSession({ workspaceId: "ws-feature", worktreeName: feature.name })
    const inherited = await createSession({
      parentSessionId: parent.id,
      workspacePlacement: "shared"
    })
    expect(inherited).toMatchObject({ workspaceId: "ws-feature", worktreeName: "feature" })
    const named = await createSession({
      parentSessionId: parent.id,
      workspacePlacement: "shared",
      worktreeName: other.name
    })
    expect(named).toMatchObject({ workspaceId: "ws-feature", worktreeName: "other" })
    vi.unstubAllEnvs()
  })

  it("stops walking corrupt cyclic ownership instead of looping", () => {
    expect(() =>
      assertWorkspaceOwner([cyclicWorkspace("a", "b"), cyclicWorkspace("b", "a")], "c", "a")
    ).not.toThrow()
  })

  it("archives a workspace's subagents with it and keeps them archived when it returns", async () => {
    const { server, createSession, workspace, patch, parent } = await fixture()
    const owned = await createSession({ parentSessionId: parent.id, workspacePlacement: "owned" })
    const nested = await createSession({ parentSessionId: owned.id, workspacePlacement: "owned" })
    const sibling = await createSession({
      parentSessionId: parent.id,
      workspacePlacement: "independent"
    })

    expect((await patch("ws-parent", { isArchived: true })).status).toBe(200)
    expect((await workspace(owned.workspaceId!)).isArchived).toBe(true)
    expect((await workspace(nested.workspaceId!)).isArchived).toBe(true)
    expect((await workspace(sibling.workspaceId!)).isArchived).toBe(false)

    expect((await patch("ws-parent", { isArchived: false })).status).toBe(200)
    expect((await workspace(owned.workspaceId!)).isArchived).toBe(true)

    // Deleting the owner archives its live subagents and releases them all.
    const fresh = await createSession({ parentSessionId: parent.id, workspacePlacement: "owned" })
    expect(
      (await jsonRequest(server, "/v1/workspaces/ws-parent", { method: "DELETE" })).status
    ).toBe(204)
    expect(await workspace(fresh.workspaceId!)).toMatchObject({ isArchived: true })
    expect((await workspace(fresh.workspaceId!)).parentWorkspaceId).toBeUndefined()
    expect((await workspace(owned.workspaceId!)).parentWorkspaceId).toBeUndefined()
    // The grandchild still belongs to its own (released) owner.
    expect((await workspace(nested.workspaceId!)).parentWorkspaceId).toBe(owned.workspaceId)
  })
})
