import { mkdtempSync, mkdirSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, worktreePath, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const useWorktreesRoot = (): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-checkouts-"))
  const previous = process.env["CODEVISOR_WORKTREES_ROOT"]
  process.env["CODEVISOR_WORKTREES_ROOT"] = root
  onTestFinished(() => {
    if (previous === undefined) delete process.env["CODEVISOR_WORKTREES_ROOT"]
    else process.env["CODEVISOR_WORKTREES_ROOT"] = previous
    rmSync(root, { force: true, recursive: true })
  })
  return root
}

const openDatabase = async (filename = tempDatabase()) => {
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  onTestFinished(() => run(db.close))
  return { db, filename }
}

const projectWithWorktree = async (db: CodevisorDatabaseService, name: string) => {
  const project = await run(db.createProject({ folderPath: `/tmp/checkouts-${name}` }))
  const worktree = await run(db.createWorktree(project.id, name, `codevisor/${name}`))
  return { project, worktree }
}

const workspaceWithChat = async (db: CodevisorDatabaseService, projectId: string, cwd: string) =>
  run(
    db.createWorkspaceWithSession({
      workspace: { projectId, name: "main", hasCustomName: false, rootDirectory: cwd },
      session: { projectId, harnessId: "codex", title: "main chat" }
    })
  )

describe("checkouts", () => {
  it("reports a chat's worktree and folder from its checkout, and a project chat's from the project folder", async () => {
    useWorktreesRoot()
    const { db, filename } = await openDatabase()
    const { project, worktree } = await projectWithWorktree(db, "from-checkout")
    const inWorktree = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", worktreeName: worktree.name })
    )
    const inProject = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const sqlite = new Database(filename)
    onTestFinished(() => {
      sqlite.close()
    })
    sqlite
      .prepare("update checkouts set path = ?, worktree_name = ? where id = ?")
      .run("/tmp/moved-worktree", "renamed", inWorktree.checkoutId)
    sqlite
      .prepare("update checkouts set path = ? where id = ?")
      .run("/tmp/stale", inProject.checkoutId)

    expect(await run(db.getSessionSummary(inWorktree.id))).toMatchObject({
      worktreeName: "renamed",
      cwd: "/tmp/moved-worktree"
    })
    expect(await run(db.getSessionSummary(inProject.id))).toMatchObject({
      cwd: "/tmp/checkouts-from-checkout"
    })
    expect((await run(db.getSessionSummary(inProject.id))).worktreeName).toBeUndefined()
  })

  it("gives a session a checkout for its project folder and the workspace that default", async () => {
    const { db } = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/checkouts-main" }))
    const created = await workspaceWithChat(db, project.id, "/tmp/checkouts-main")

    const checkouts = await run(db.listCheckouts)
    expect(checkouts).toHaveLength(1)
    expect(checkouts[0]).toMatchObject({ path: "/tmp/checkouts-main" })
    expect(created.session.checkoutId).toBe(checkouts[0]?.id)
    expect(created.workspace.defaultCheckoutId).toBe(checkouts[0]?.id)
    expect(created.pane.checkoutId).toBe(checkouts[0]?.id)
  })

  it("adopts the first chat's checkout as the default of a workspace created without a root", async () => {
    const { db } = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/checkouts-adopt" }))
    const created = await run(
      db.createWorkspaceWithSession({
        workspace: { projectId: project.id, name: "adopt", hasCustomName: false },
        session: { projectId: project.id, harnessId: "codex" }
      })
    )
    expect(created.workspace.defaultCheckoutId).toBe(created.session.checkoutId)

    const bare = await run(
      db.upsertWorkspace({ projectId: project.id, name: "bare", hasCustomName: false })
    )
    const moved = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(moved.id, bare.id))
    const adopted = (await run(db.listWorkspaces)).find((w) => w.id === bare.id)
    expect(adopted?.defaultCheckoutId).toBe(moved.checkoutId)
  })

  it("keeps a worktree chat on its own checkout inside the parent's workspace", async () => {
    useWorktreesRoot()
    const { db } = await openDatabase()
    const { project, worktree } = await projectWithWorktree(db, "helper")
    const parent = await workspaceWithChat(db, project.id, `/tmp/checkouts-helper`)
    const child = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        worktreeName: worktree.name,
        workspaceId: parent.workspace.id,
        createdByAgentId: parent.session.id,
        createdByAgentMachineId: "local"
      })
    )
    await run(db.setSessionWorkspace(child.id, parent.workspace.id))

    const childCheckout = (await run(db.listCheckouts)).find((c) => c.id === child.checkoutId)
    expect(childCheckout).toMatchObject({
      path: worktreePath(project.id, worktree.name),
      worktreeName: worktree.name,
      worktreeId: worktree.id
    })
    const panes = await run(db.listWorkspacePanes)
    const childPane = panes.find((pane) => pane.resourceId === child.id)
    expect(childPane?.workspaceId).toBe(parent.workspace.id)
    expect(childPane?.checkoutId).toBe(child.checkoutId)
    expect(childPane?.checkoutId).not.toBe(parent.pane.checkoutId)
  })

  it("puts a terminal pane in the workspace's default checkout unless told otherwise", async () => {
    useWorktreesRoot()
    const { db } = await openDatabase()
    const { project, worktree } = await projectWithWorktree(db, "term")
    const parent = await workspaceWithChat(db, project.id, "/tmp/checkouts-term")
    const elsewhere = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        worktreeName: worktree.name,
        workspaceId: parent.workspace.id
      })
    )
    const other = { id: elsewhere.checkoutId }

    const defaulted = await run(
      db.upsertWorkspacePane(parent.workspace.id, {
        providerId: "codevisor",
        paneType: "terminal",
        title: "Terminal"
      })
    )
    const placed = await run(
      db.upsertWorkspacePane(parent.workspace.id, {
        providerId: "codevisor",
        paneType: "terminal",
        title: "Terminal",
        checkoutId: other.id,
        resourceServerId: "remote-box"
      })
    )
    expect(defaulted.checkoutId).toBe(parent.workspace.defaultCheckoutId)
    expect(placed.checkoutId).toBe(other.id)
    expect(placed.resourceServerId).toBe("remote-box")
  })

  it("counts a checkout as in use while a live chat, tab, or workspace points at it", async () => {
    useWorktreesRoot()
    const { db } = await openDatabase()
    const { project, worktree } = await projectWithWorktree(db, "used")
    const parent = await workspaceWithChat(db, project.id, "/tmp/checkouts-used")
    const wrapper = await run(
      db.createWorkspaceWithSession({
        workspace: {
          projectId: project.id,
          name: "wrapper",
          hasCustomName: false,
          rootDirectory: worktreePath(project.id, worktree.name)
        },
        session: { projectId: project.id, harnessId: "codex", worktreeName: worktree.name }
      })
    )
    const checkoutId = wrapper.session.checkoutId!
    await run(db.setSessionWorkspace(wrapper.session.id, parent.workspace.id))

    await run(db.updateWorkspace(wrapper.workspace.id, { isArchived: true }))
    expect(await run(db.isCheckoutInUse(checkoutId))).toBe(true)

    await run(db.archiveSession(wrapper.session.id))
    expect(await run(db.isCheckoutInUse(checkoutId))).toBe(true)

    await run(db.deleteWorkspacePane(parent.workspace.id, wrapper.pane.id))
    expect(await run(db.isCheckoutInUse(checkoutId))).toBe(false)

    await run(db.updateWorkspace(wrapper.workspace.id, { isArchived: false }))
    expect(await run(db.isCheckoutInUse(checkoutId))).toBe(true)
  })

  it("finds the workspace showing a session through its pane, then its parent", async () => {
    const { db } = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/checkouts-showing" }))
    const parent = await workspaceWithChat(db, project.id, "/tmp/checkouts-showing")
    const shown = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        workspaceId: parent.workspace.id
      })
    )
    await run(db.setSessionWorkspace(shown.id, parent.workspace.id))
    const hidden = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        createdByAgentId: shown.id,
        createdByAgentMachineId: "local"
      })
    )
    const own = await run(
      db.upsertWorkspace({ projectId: project.id, name: "own", hasCustomName: false })
    )
    const elsewhere = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        createdByAgentId: shown.id,
        createdByAgentMachineId: "another-machine",
        workspaceId: own.id
      })
    )

    expect(await run(db.findWorkspaceShowingSession(shown.id))).toBe(parent.workspace.id)
    expect(await run(db.findWorkspaceShowingSession(hidden.id))).toBe(parent.workspace.id)
    expect(await run(db.findWorkspaceShowingSession(elsewhere.id))).toBe(own.id)
  })

  it("mirrors workspace git onto the default checkout", async () => {
    const { db } = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/checkouts-git" }))
    const created = await workspaceWithChat(db, project.id, "/tmp/checkouts-git")

    await run(db.setWorkspaceGit(created.workspace.id, { branch: "feature" }, null))

    const checkout = (await run(db.listCheckouts)).find(
      (c) => c.id === created.workspace.defaultCheckoutId
    )
    expect(checkout?.git).toEqual({ branch: "feature", pullRequest: null })
  })

  it("backfills checkouts for databases created before the table existed", async () => {
    const root = useWorktreesRoot()
    const { db, filename } = await openDatabase()
    const { project, worktree } = await projectWithWorktree(db, "legacy")
    mkdirSync(join(root, "worktrees.noindex", project.id, worktree.name), { recursive: true })
    const retired = await workspaceWithChat(db, project.id, "/tmp/checkouts-legacy")
    await run(db.setWorkspaceGit(retired.workspace.id, { branch: "retired" }, null))
    await run(db.updateWorkspace(retired.workspace.id, { isArchived: true }))
    const parent = await workspaceWithChat(db, project.id, "/tmp/checkouts-legacy")
    const child = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        worktreeName: worktree.name,
        workspaceId: parent.workspace.id
      })
    )
    await run(db.setSessionWorkspace(child.id, parent.workspace.id))
    await run(db.setWorkspaceGit(parent.workspace.id, { branch: "main" }, null))
    await run(db.close)

    const sqlite = new Database(filename)
    try {
      sqlite.exec(rewindCheckoutsSql)
    } finally {
      sqlite.close()
    }

    const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
    onTestFinished(() => run(upgraded.close))
    const checkouts = await run(upgraded.listCheckouts)
    const byPath = new Map(checkouts.map((c) => [c.path, c]))
    expect(byPath.get("/tmp/checkouts-legacy")?.git).toEqual({ branch: "main", pullRequest: null })
    expect(byPath.get(worktreePath(project.id, worktree.name))).toMatchObject({
      worktreeName: worktree.name,
      worktreeId: worktree.id
    })
    const sessions = await run(upgraded.listSessions)
    expect(sessions.find((s) => s.id === child.id)?.checkoutId).toBe(
      byPath.get(worktreePath(project.id, worktree.name))?.id
    )
    const workspace = (await run(upgraded.listWorkspaces)).find((w) => w.id === parent.workspace.id)
    expect(workspace?.defaultCheckoutId).toBe(byPath.get("/tmp/checkouts-legacy")?.id)
    const panes = await run(upgraded.listWorkspacePanes)
    expect(panes.find((p) => p.resourceId === child.id)?.checkoutId).toBe(
      sessions.find((s) => s.id === child.id)?.checkoutId
    )
  })
})

const rewindCheckoutsSql = `
  drop index workspace_panes_checkout_idx;
  drop index sessions_checkout_idx;
  alter table workspace_panes drop column resource_server_id;
  alter table workspace_panes drop column checkout_id;
  alter table sessions drop column checkout_id;
  alter table workspaces drop column default_checkout_id;
  drop table checkouts;
  delete from schema_migrations where id = 99;
`
