import type { Harness } from "@codevisor/api"
import Database from "better-sqlite3"
import { Effect } from "effect"
import { homedir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { DatabaseError, makeDatabase, worktreePath } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("re-homes a session to another project, dropping stale worktree names", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const origin = await run(db.createProject({ folderPath: "/tmp/move-origin" }))
    const destination = await run(db.createProject({ folderPath: "/tmp/move-destination" }))
    await run(db.createWorktree(origin.id, "fix-auth", "codevisor/fix-auth"))
    const session = await run(
      db.createSession({
        projectId: origin.id,
        harnessId: "codex",
        worktreeName: "fix-auth"
      })
    )

    // A project move re-homes the session's directory: the old project's
    // worktree name must not survive it.
    const moved = await run(db.updateSession(session.id, { projectId: destination.id }))
    expect(moved.projectId).toBe(destination.id)
    expect(moved.worktreeName).toBeUndefined()
    expect(moved.cwd).toBe("/tmp/move-destination")

    // A move can carry the destination worktree explicitly, and Swift's
    // uppercase ids canonicalize like every other write.
    await run(db.createWorktree(destination.id, "spry-otter", "codevisor/spry-otter"))
    const movedBack = await run(
      db.updateSession(session.id, {
        projectId: destination.id.toUpperCase(),
        worktreeName: "spry-otter"
      })
    )
    expect(movedBack.projectId).toBe(destination.id)
    expect(movedBack.worktreeName).toBe("spry-otter")
    expect(movedBack.cwd).toBe(worktreePath(destination.id, "spry-otter"))
  })

  it("round-trips the git remote a project was cloned from", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const cloned = await run(
      db.createProject({
        folderPath: "/home/user/.codevisor/repos/widget",
        name: "widget",
        repoUrl: "https://github.com/acme/widget.git"
      })
    )
    expect(cloned.repoUrl).toBe("https://github.com/acme/widget.git")
    const listed = await run(db.listProjects)
    expect(listed.find((project) => project.id === cloned.id)?.repoUrl).toBe(
      "https://github.com/acme/widget.git"
    )
    // Directory projects carry no remote.
    const plain = await run(db.createProject({ folderPath: "/tmp/plain-dir" }))
    expect(plain.repoUrl).toBeUndefined()
    await run(db.close)
  })

  it("persists a stable instance id across reopens", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const first = await run(db.getOrCreateInstanceId)
    expect(first).toMatch(/^[0-9a-f-]{36}$/)
    expect(await run(db.getOrCreateInstanceId)).toBe(first)
    await run(db.close)

    const reopened = await run(makeDatabase({ filename, serverId: "renamed" }))
    expect(await run(reopened.getOrCreateInstanceId)).toBe(first)
    await run(reopened.close)
  })

  it("keeps the connection token stable across reopens and rotates on demand", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const token = await run(db.getOrCreateConnectionToken)
    expect(token).toMatch(/^hm_/)
    // Stable within a run and verifiable as a bearer token.
    expect(await run(db.getOrCreateConnectionToken)).toBe(token)
    expect(await run(db.verifyBearerToken(token))).toBe(true)
    await run(db.close)

    // Survives a restart/update (reopen with a different serverId).
    const reopened = await run(makeDatabase({ filename, serverId: "renamed" }))
    expect(await run(reopened.getOrCreateConnectionToken)).toBe(token)

    // Rotation issues a new token and retires the old one.
    const rotated = await run(reopened.rotateConnectionToken)
    expect(rotated).not.toBe(token)
    expect(await run(reopened.getOrCreateConnectionToken)).toBe(rotated)
    expect(await run(reopened.verifyBearerToken(rotated))).toBe(true)
    expect(await run(reopened.verifyBearerToken(token))).toBe(false)
    await run(reopened.close)
  })

  it("can rotate a connection token that was never issued", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const token = await run(db.rotateConnectionToken)
    expect(token).toMatch(/^hm_/)
    expect(await run(db.verifyBearerToken(token))).toBe(true)
    await run(db.close)
  })

  it("persists and clears the preferred Browser Use backend", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(db.getBrowserPreference)).toBeUndefined()
    await run(db.setBrowserPreference("chrome"))
    expect(await run(db.getBrowserPreference)).toBe("chrome")
    await run(db.close)

    const reopened = await run(makeDatabase({ filename, serverId: "renamed" }))
    expect(await run(reopened.getBrowserPreference)).toBe("chrome")
    await run(reopened.setBrowserPreference("managed"))
    expect(await run(reopened.getBrowserPreference)).toBe("managed")
    await run(reopened.setBrowserPreference(undefined))
    expect(await run(reopened.getBrowserPreference)).toBeUndefined()
    await run(reopened.close)
  })

  it("cascades project archive to workspaces and sessions, and reverses only what it archived", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/cascade" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "main", hasCustomName: false })
    )
    const cascaded = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const handArchived = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    // The user archives one chat by hand, well before the project is archived.
    await run(db.updateSession(handArchived.id, { isArchived: true }))
    const handStamp = (await run(db.getSessionSummary(handArchived.id))).archivedAt
    expect(handStamp).toBeDefined()

    await run(db.updateProject(project.id, { isArchived: true }))
    expect((await run(db.getSessionSummary(cascaded.id))).isArchived).toBe(true)
    expect((await run(db.listWorkspaces)).find((w) => w.id === workspace.id)?.isArchived).toBe(true)
    // The hand-archived chat keeps its original moment: the cascade must not
    // restamp rows it did not archive.
    expect((await run(db.getSessionSummary(handArchived.id))).archivedAt).toBe(handStamp)

    await run(db.updateProject(project.id, { isArchived: false }))
    expect((await run(db.getSessionSummary(cascaded.id))).isArchived).toBe(false)
    expect((await run(db.listWorkspaces)).find((w) => w.id === workspace.id)?.isArchived).toBe(
      false
    )
    // The whole point of provenance: this one stays archived.
    expect((await run(db.getSessionSummary(handArchived.id))).isArchived).toBe(true)
    await run(db.close)
  })

  it("cascades workspace archive to its sessions without touching siblings", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/ws-cascade" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "feature", hasCustomName: false })
    )
    const inside = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const outside = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(inside.id, workspace.id))

    await run(db.updateWorkspace(workspace.id, { isArchived: true }))
    expect((await run(db.getSessionSummary(inside.id))).isArchived).toBe(true)
    expect((await run(db.getSessionSummary(outside.id))).isArchived).toBe(false)

    await run(db.updateWorkspace(workspace.id, { isArchived: false }))
    expect((await run(db.getSessionSummary(inside.id))).isArchived).toBe(false)
    await run(db.close)
  })

  it("cascades through a full workspace upsert, not just a patch", async () => {
    // The macOS client writes workspaces with PUT, so the upsert path owes
    // the same cascade a PATCH does — otherwise archiving from that client
    // would hide the workspace while leaving its chats in the sidebar.
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/ws-upsert-cascade" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "feature", hasCustomName: false })
    )
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(session.id, workspace.id))

    await run(
      db.upsertWorkspace({
        id: workspace.id,
        projectId: project.id,
        name: "feature",
        hasCustomName: false,
        isArchived: true
      })
    )
    expect((await run(db.getSessionSummary(session.id))).isArchived).toBe(true)

    await run(
      db.upsertWorkspace({
        id: workspace.id,
        projectId: project.id,
        name: "feature",
        hasCustomName: false,
        isArchived: false
      })
    )
    expect((await run(db.getSessionSummary(session.id))).isArchived).toBe(false)
    await run(db.close)
  })

  it("preserves untouched workspace fields and the original archived moment", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/ws-partial" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "pinned", hasCustomName: true })
    )
    await run(db.updateWorkspace(workspace.id, { isArchived: true }))
    const firstStamp = (await run(db.listWorkspaces)).find(
      (candidate) => candidate.id === workspace.id
    )?.archivedAt

    // A rename that says nothing about naming or archiving must not silently
    // clear the custom-name pin or re-stamp the archive moment.
    const renamed = await run(db.updateWorkspace(workspace.id, { name: "still pinned" }))

    expect(renamed.name).toBe("still pinned")
    expect(renamed.hasCustomName).toBe(true)
    expect(renamed.isArchived).toBe(true)
    expect(renamed.archivedAt).toBe(firstStamp)
    await run(db.close)
  })

  it("re-archiving an already archived workspace does not cascade again", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/ws-rearchive" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "feature", hasCustomName: false })
    )
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(session.id, workspace.id))
    await run(db.updateWorkspace(workspace.id, { isArchived: true }))

    // Restore the chat by hand, then re-archive the already-archived
    // workspace: the no-op transition must not drag the chat back down.
    await run(db.updateSession(session.id, { isArchived: false }))
    await run(db.updateWorkspace(workspace.id, { isArchived: true }))

    expect((await run(db.getSessionSummary(session.id))).isArchived).toBe(false)
    await run(db.close)
  })

  it("rejects updating a workspace that does not exist", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    await expect(
      run(db.updateWorkspace("6f1d5f9e-1c2b-4a3d-8e5f-0a1b2c3d4e5f", { isArchived: true }))
    ).rejects.toThrow(/Workspace not found/)
    await run(db.close)
  })

  it("keeps the original archived moment when an archived row is updated again", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/stamp" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(db.updateSession(session.id, { isArchived: true }))
    const first = (await run(db.getSessionSummary(session.id))).archivedAt
    // An unrelated field changes while the chat stays archived.
    await run(db.updateSession(session.id, { title: "renamed while archived" }))
    const after = await run(db.getSessionSummary(session.id))
    expect(after.archivedAt).toBe(first)
    expect(after.title).toBe("renamed while archived")

    // Unarchiving clears the stamp entirely.
    await run(db.updateSession(session.id, { isArchived: false }))
    expect((await run(db.getSessionSummary(session.id))).archivedAt).toBeUndefined()
    await run(db.close)
  })

  it("stores archived worktrees keyed by id so the name returns to the pool", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/archived-worktrees" }))
    const worktree = await run(db.createWorktree(project.id, "sushi", "codevisor/sushi"))
    const record = await run(
      db.createArchivedWorktree({
        id: worktree.id,
        projectId: project.id,
        serverId: "local",
        originalName: "sushi",
        branch: "codevisor/sushi",
        parentSha: "a".repeat(40),
        snapshotRef: `refs/codevisor/archived/${worktree.id}`,
        createdAt: "2026-07-01T00:00:00.000Z"
      })
    )
    await run(db.deleteWorktree(worktree.id))

    // The live row is gone (name is free again) but the snapshot record remains.
    expect(await run(db.listWorktrees(project.id))).toEqual([])
    expect(await run(db.findArchivedWorktree(project.id, "local", "sushi"))).toEqual(record)
    expect((await run(db.listArchivedWorktrees(project.id))).length).toBe(1)

    await run(db.deleteArchivedWorktree(worktree.id))
    expect(await run(db.findArchivedWorktree(project.id, "local", "sushi"))).toBeUndefined()
    await run(db.close)
  })

  it("persists harness accounts, selection, auth state, and session bindings", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ name: "Auth", folderPath: "/tmp/auth" }))

    const defaultAccount = await run(
      db.saveHarnessAccount({
        id: "default-codex",
        harnessId: "codex",
        profileKind: "default",
        label: "Existing account",
        authState: "checking",
        canLogin: true,
        canLogout: false
      })
    )
    expect(defaultAccount.isActive).toBe(true)
    const updatedDefault = await run(
      db.saveHarnessAccount({
        id: "ignored-duplicate-id",
        harnessId: "codex",
        profileKind: "default",
        label: "Detected account",
        email: "person@example.com",
        organizationId: "org-1",
        authMethod: "chatgpt",
        authState: "authenticated",
        canLogin: true,
        canLogout: true,
        lastCheckedAt: "2026-07-10T00:00:00.000Z",
        detail: "Plus"
      })
    )
    expect(updatedDefault.id).toBe(defaultAccount.id)
    const expiredDefault = await run(
      db.updateHarnessAccountAuth(updatedDefault.id, { authState: "expired" })
    )
    expect(expiredDefault).toMatchObject({
      email: "person@example.com",
      organizationId: "org-1",
      authMethod: "chatgpt",
      detail: "Plus"
    })
    await expect(
      run(db.updateHarnessAccountAuth("missing-account", { authState: "error" }))
    ).rejects.toBeInstanceOf(DatabaseError)

    const managed = await run(
      db.saveHarnessAccount({
        id: "managed-codex",
        harnessId: "codex",
        profileKind: "managed",
        profileKey: "profile-a",
        label: "Work",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const sameManaged = await run(
      db.saveHarnessAccount({
        harnessId: "codex",
        profileKind: "managed",
        profileKey: "profile-a",
        label: "Work renamed",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    expect(sameManaged.id).toBe(managed.id)
    expect((await run(db.listHarnessAccounts("codex"))).length).toBe(2)
    expect(await run(db.getHarnessAccount("missing"))).toBeUndefined()

    const authenticated = await run(
      db.updateHarnessAccountAuth(managed.id, {
        label: "Work account",
        email: "work@example.com",
        organizationId: null,
        authMethod: "device",
        authState: "authenticated",
        canLogin: false,
        canLogout: true,
        lastCheckedAt: "2026-07-10T01:00:00.000Z",
        detail: null
      })
    )
    expect(authenticated).toMatchObject({ email: "work@example.com", canLogout: true })
    const refreshed = await run(
      db.updateHarnessAccountAuth(managed.id, { authState: "authenticated" })
    )
    expect(refreshed.organizationId).toBeUndefined()
    expect(refreshed.detail).toBeUndefined()
    await run(db.setActiveHarnessAccount("codex", managed.id))
    expect((await run(db.getHarnessAccount(managed.id)))?.isActive).toBe(true)

    const session = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", harnessAccountId: managed.id })
    )
    expect(session.harnessAccountId).toBe(managed.id)
    await expect(run(db.removeHarnessAccount(managed.id))).rejects.toBeInstanceOf(DatabaseError)
    await expect(run(db.removeHarnessAccount(defaultAccount.id))).rejects.toBeInstanceOf(
      DatabaseError
    )

    const removable = await run(
      db.saveHarnessAccount({
        harnessId: "codex",
        profileKind: "managed",
        label: "Temporary",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const passive = await run(
      db.saveHarnessAccount({
        harnessId: "claude-code",
        profileKind: "managed",
        label: "Passive",
        authState: "notRequired",
        canLogin: false,
        canLogout: true
      })
    )
    expect(passive).toMatchObject({ canLogin: false, canLogout: true })
    await run(db.updateHarnessAccountAuth(passive.id, { authState: "notRequired" }))
    await run(db.updateHarnessAccountAuth(removable.id, { authState: "unauthenticated" }))
    await expect(
      run(db.setActiveHarnessAccount("claude-code", removable.id))
    ).rejects.toBeInstanceOf(DatabaseError)
    await run(db.removeHarnessAccount(removable.id))
    expect(await run(db.getHarnessAccount(removable.id))).toBeUndefined()

    const legacy = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    expect(
      (await run(db.bindSessionHarnessAccount(legacy.id, defaultAccount.id))).harnessAccountId
    ).toBe(defaultAccount.id)
    await Effect.runPromise(db.close)
  })

  it("persists the resolved config selections for each session", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/session-config" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    expect(await run(db.getSessionConfigSelections(session.id))).toEqual({})
    await expect(run(db.getSessionConfigSelections("missing-session"))).rejects.toThrow(
      "Session not found: missing-session"
    )
    await run(
      db.replaceSessionConfigSelections(session.id, {
        model: "gpt-5.6-sol",
        reasoning: "high",
        speed: "standard"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).configSelections).toEqual({
      model: "gpt-5.6-sol",
      reasoning: "high",
      speed: "standard"
    })
    await Effect.runPromise(db.close)

    const reopened = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(reopened.getSessionConfigSelections(session.id))).toEqual({
      model: "gpt-5.6-sol",
      reasoning: "high",
      speed: "standard"
    })
    await Effect.runPromise(reopened.close)

    const sqlite = new Database(filename)
    sqlite
      .prepare("update sessions set config_selections = ? where id = ?")
      .run("not-json", session.id)
    sqlite.close()
    const recovered = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(recovered.getSessionConfigSelections(session.id))).toEqual({})
    await Effect.runPromise(recovered.close)
  })

  it("persists, lists, updates, and deletes pane workspaces", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/pane-workspaces" }))

    const created = await run(
      db.upsertWorkspace({
        id: "workspace-1",
        projectId: project.id,
        name: "Main",
        hasCustomName: false,
        createdAt: "2026-07-01T00:00:00.000Z"
      })
    )
    expect(created).toEqual({
      id: "workspace-1",
      serverId: "machine-a",
      projectId: project.id,
      name: "Main",
      hasCustomName: false,
      isArchived: false,
      createdAt: "2026-07-01T00:00:00.000Z"
    })

    // Omitted ids and creation dates are generated server-side.
    const generated = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Scratch", hasCustomName: false })
    )
    expect(generated.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(Date.parse(generated.createdAt)).not.toBeNaN()

    // Re-upserting the same id updates in place, stamps updated_at, and keeps
    // the original creation date.
    const updated = await run(
      db.upsertWorkspace({
        id: "workspace-1",
        projectId: project.id,
        name: "Renamed",
        hasCustomName: true,
        symbolName: "hammer",
        rootDirectory: "/tmp/pane-workspaces/worktree",
        isArchived: true,
        createdAt: "2026-07-02T00:00:00.000Z"
      })
    )
    expect(updated).toMatchObject({
      id: "workspace-1",
      name: "Renamed",
      hasCustomName: true,
      symbolName: "hammer",
      rootDirectory: "/tmp/pane-workspaces/worktree",
      isArchived: true,
      createdAt: "2026-07-01T00:00:00.000Z"
    })
    expect(updated.updatedAt).toBeDefined()
    expect(created.updatedAt).toBeUndefined()

    // Newest first.
    expect((await run(db.listWorkspaces)).map((workspace) => workspace.id)).toEqual([
      generated.id,
      "workspace-1"
    ])

    // A workspace cannot exist without its project.
    await expect(
      run(db.upsertWorkspace({ projectId: "missing", name: "Nope", hasCustomName: false }))
    ).rejects.toBeInstanceOf(DatabaseError)

    await run(db.deleteWorkspace(generated.id))
    expect((await run(db.listWorkspaces)).map((workspace) => workspace.id)).toEqual(["workspace-1"])
    await expect(run(db.deleteWorkspace("missing"))).rejects.toBeInstanceOf(DatabaseError)

    // Deleting a project cascades its workspaces (and their sessions) away.
    const session = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", workspaceId: "workspace-1" })
    )
    await run(db.deleteProject(project.id))
    expect(await run(db.listWorkspaces)).toEqual([])
    await expect(run(db.getSessionSummary(session.id))).rejects.toBeInstanceOf(DatabaseError)
    await Effect.runPromise(db.close)
  })

  it("binds sessions to pane workspaces at creation and afterwards", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/workspace-sessions" }))
    const workspace = await run(
      db.upsertWorkspace({
        id: "workspace-1",
        projectId: project.id,
        name: "Main",
        hasCustomName: false
      })
    )

    const attached = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", workspaceId: workspace.id })
    )
    expect(attached.workspaceId).toBe(workspace.id)
    expect(
      (await run(db.listSessions)).find((session) => session.id === attached.id)?.workspaceId
    ).toBe(workspace.id)

    const detached = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    expect(detached.workspaceId).toBeUndefined()

    await run(db.setSessionWorkspace(detached.id, workspace.id))
    expect((await run(db.getSessionSummary(detached.id))).workspaceId).toBe(workspace.id)
    await run(db.setSessionWorkspace(detached.id, null))
    expect((await run(db.getSessionSummary(detached.id))).workspaceId).toBeUndefined()

    await expect(run(db.setSessionWorkspace("missing", workspace.id))).rejects.toBeInstanceOf(
      DatabaseError
    )
    // A session cannot point at a workspace that does not exist.
    await expect(
      run(db.setSessionWorkspace(detached.id, "missing-workspace"))
    ).rejects.toBeInstanceOf(DatabaseError)
    await Effect.runPromise(db.close)
  })

  it("stores file blobs and threads attachments through queue and conversation rows", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/attachments" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
    const metadata = await run(db.createFile("shot.png", "image/png", "image", bytes))
    expect(metadata).toMatchObject({
      name: "shot.png",
      mimeType: "image/png",
      sizeBytes: bytes.byteLength,
      kind: "image"
    })
    expect(metadata.sha256).toHaveLength(64)

    const stored = await run(db.getFile(metadata.id))
    expect(stored?.metadata).toEqual(metadata)
    expect(stored?.data.equals(bytes)).toBe(true)
    expect(await run(db.getFileMetadata(metadata.id))).toEqual(metadata)
    expect(await run(db.getFile("missing-file"))).toBeUndefined()
    expect(await run(db.getFileMetadata("missing-file"))).toBeUndefined()

    const ref = {
      fileId: metadata.id,
      name: metadata.name,
      mimeType: metadata.mimeType,
      sizeBytes: metadata.sizeBytes,
      kind: metadata.kind
    }
    const queued = await run(db.createPromptQueueItem(session.id, "with file", [ref]))
    expect(queued.attachments).toEqual([ref])
    expect((await run(db.listPromptQueue(session.id)))[0]?.attachments).toEqual([ref])
    expect(await run(db.claimPromptQueueItem(session.id))).toMatchObject({
      text: "with file",
      attachments: [ref]
    })
    await run(db.completePromptQueueItem(session.id, queued.id))
    const queuedPlain = await run(db.createPromptQueueItem(session.id, "no file", []))
    expect(queuedPlain.attachments).toBeUndefined()
    expect(await run(db.claimPromptQueueItem(session.id))).toMatchObject({ text: "no file" })

    await run(
      db.appendConversationItem(session.id, "user", undefined, "look at this", false, [ref])
    )
    await run(db.appendConversationItem(session.id, "assistant", undefined, "nice", false))
    const detail = await run(db.getSessionDetail(session.id))
    expect(detail.conversation[0]?.attachments).toEqual([ref])
    expect(detail.conversation[1]?.attachments).toBeUndefined()

    // A literal empty JSON array in the canonical item reads back as "no attachments".
    const sqlite = new Database(filename)
    sqlite.prepare("update chat_items set attachments = '[]' where session_id = ?").run(session.id)
    sqlite.close()
    const emptied = await run(db.getSessionDetail(session.id))
    expect(emptied.conversation[0]?.attachments).toBeUndefined()

    await Effect.runPromise(db.close)
  })

  it("tracks worktrees and derives worktree session cwds", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/worktree-project" }))

    const worktree = await run(db.createWorktree(project.id, "fix-auth", "codevisor/fix-auth"))
    expect(worktree).toMatchObject({
      projectId: project.id,
      serverId: "local",
      name: "fix-auth",
      branch: "codevisor/fix-auth",
      path: join(homedir(), "codevisor", project.id, "fix-auth")
    })
    expect(worktree.path).toBe(worktreePath(project.id, "fix-auth"))

    expect(await run(db.listWorktrees(project.id))).toEqual([worktree])
    expect(await run(db.listWorktrees("missing"))).toEqual([])

    // Same name for the same project on the same server is rejected.
    await expect(
      run(db.createWorktree(project.id, "fix-auth", "codevisor/fix-auth-2"))
    ).rejects.toBeInstanceOf(DatabaseError)
    await expect(
      run(db.createWorktree("missing", "fix-auth", "codevisor/fix-auth"))
    ).rejects.toBeInstanceOf(DatabaseError)

    const session = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        worktreeName: "fix-auth"
      })
    )
    expect(session.worktreeName).toBe("fix-auth")
    expect(session.cwd).toBe(worktreePath(project.id, "fix-auth"))

    const doomed = await run(db.createWorktree(project.id, "doomed", "codevisor/doomed"))
    await run(db.deleteWorktree(doomed.id))
    expect((await run(db.listWorktrees(project.id))).map((w) => w.name)).toEqual(["fix-auth"])
    // Deleting an unknown worktree is a no-op rather than an error.
    await run(db.deleteWorktree("missing"))

    // Worktree rows are removed with their project.
    await run(db.deleteProject(project.id))
    expect(await run(db.listWorktrees(project.id))).toEqual([])

    await Effect.runPromise(db.close)
  })

  it("omits session cwd when the project has no folder on this server", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/elsewhere" }))
    await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await Effect.runPromise(db.close)

    // A server without a location for the project cannot derive a cwd.
    const other = await run(makeDatabase({ filename, serverId: "machine-b" }))
    const sessions = await run(other.listSessions)
    expect(sessions[0]?.cwd).toBeUndefined()
    await Effect.runPromise(other.close)
  })

  it("applies harness settings, auth tokens, and update state", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "server-a" }))
    const harnesses: ReadonlyArray<Harness> = [
      {
        id: "codex",
        name: "Codex",
        symbolName: "chevron.left.forwardslash.chevron.right",
        source: "registry",
        launchKind: "npx",
        enabled: true,
        readiness: { state: "ready" }
      },
      {
        id: "claude-code",
        name: "Claude Code",
        symbolName: "sparkle",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: { state: "unavailable", detail: "missing" }
      }
    ]

    expect(await run(db.applyHarnessSettings(harnesses))).toEqual(harnesses)
    await run(db.setHarnessEnabled("codex", false))
    expect(
      (await run(db.applyHarnessSettings(harnesses))).map((harness) => harness.enabled)
    ).toEqual([false, true])
    await run(db.setHarnessEnabled("codex", true))
    expect(
      (await run(db.applyHarnessSettings(harnesses))).map((harness) => harness.enabled)
    ).toEqual([true, true])

    const token = await run(db.issuePairingToken)
    expect(token.startsWith("hm_")).toBe(true)
    expect(await run(db.verifyBearerToken(token))).toBe(true)
    expect(await run(db.verifyBearerToken("hm_wrong"))).toBe(false)

    expect(await run(db.getUpdateInfo)).toMatchObject({
      currentVersion: "0.1.0",
      updateAvailable: false,
      migrationState: "idle"
    })
    const update = await run(
      db.setUpdateInfo({
        currentVersion: "0.1.0",
        latestVersion: "0.2.0",
        updateAvailable: true,
        channel: "development",
        checkedAt: "2026-06-30T01:00:00.000Z",
        migrationState: "running"
      })
    )
    expect(update.updateAvailable).toBe(true)
    expect(await run(db.getUpdateInfo)).toEqual(update)
    expect(
      await run(
        db.setUpdateInfo({
          currentVersion: "0.2.0",
          latestVersion: "0.2.0",
          updateAvailable: false,
          channel: "stable",
          migrationState: "idle"
        })
      )
    ).toEqual({
      currentVersion: "0.2.0",
      latestVersion: "0.2.0",
      updateAvailable: false,
      channel: "stable",
      migrationState: "idle"
    })

    await Effect.runPromise(db.close)
  })

  it("round-trips harness update state and pending updates", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))

    // Latest-version knowledge: empty → upsert (sparse and full) → list.
    expect(await run(db.listHarnessUpdateStates)).toEqual([])
    const sparse = await run(
      db.setHarnessUpdateState({ harnessId: "codex", info: { updateAvailable: false } })
    )
    expect(sparse.info.updateAvailable).toBe(false)
    expect(await run(db.listHarnessUpdateStates)).toEqual([
      { harnessId: "codex", info: { updateAvailable: false } }
    ])
    const full = {
      harnessId: "codex",
      info: {
        updateAvailable: true,
        installedVersion: "0.144.6",
        latestVersion: "0.145.0",
        source: "brew",
        installOrigin: "brew",
        channel: "stable",
        checkedAt: "2026-07-20T00:00:00.000Z"
      }
    }
    await run(db.setHarnessUpdateState(full))
    expect(await run(db.listHarnessUpdateStates)).toEqual([full])

    // Pending updates: empty → armed (sparse) → running (full) → cleared.
    expect(await run(db.listHarnessPendingUpdates)).toEqual([])
    await run(
      db.setHarnessPendingUpdate({
        harnessId: "codex",
        state: "pending",
        requestedAt: "2026-07-20T00:01:00.000Z"
      })
    )
    expect(await run(db.listHarnessPendingUpdates)).toEqual([
      { harnessId: "codex", state: "pending", requestedAt: "2026-07-20T00:01:00.000Z" }
    ])
    const running = {
      harnessId: "codex",
      state: "running" as const,
      targetVersion: "0.145.0",
      requestedAt: "2026-07-20T00:01:00.000Z",
      startedAt: "2026-07-20T00:02:00.000Z",
      timeoutAt: "2026-07-20T00:12:00.000Z"
    }
    expect(await run(db.setHarnessPendingUpdate(running))).toEqual(running)
    expect(await run(db.listHarnessPendingUpdates)).toEqual([running])
    await run(db.clearHarnessPendingUpdate("codex"))
    expect(await run(db.listHarnessPendingUpdates)).toEqual([])
    // Clearing an absent row is a no-op, not an error.
    await run(db.clearHarnessPendingUpdate("codex"))

    await Effect.runPromise(db.close)
  })

  it("persists MCP server configuration and encrypted credential payloads", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const created = await run(
      db.saveMcpServer({
        name: "Linear",
        transport: "http",
        url: "https://example.test/mcp",
        enabled: true,
        authType: "oauth",
        oauthScope: "read write",
        connectionState: "needsAuthorization",
        toolCount: 0,
        secretCipher: "opaque-ciphertext"
      })
    )
    expect(created).toMatchObject({
      authType: "oauth",
      canEdit: true,
      canRemove: true,
      enabled: true,
      kind: "managed",
      name: "Linear",
      secretCipher: "opaque-ciphertext",
      transport: "http"
    })

    const updated = await run(
      db.saveMcpServer({
        id: created.id,
        name: created.name,
        transport: created.transport,
        ...(created.url === undefined ? {} : { url: created.url }),
        ...(created.command === undefined ? {} : { command: created.command }),
        args: created.args,
        enabled: created.enabled,
        authType: created.authType,
        ...(created.oauthScope === undefined ? {} : { oauthScope: created.oauthScope }),
        connectionState: "connected",
        toolCount: 18,
        ...(created.secretCipher === undefined ? {} : { secretCipher: created.secretCipher })
      })
    )
    expect(updated.connectionState).toBe("connected")
    expect((await run(db.listMcpServers))[0]?.toolCount).toBe(18)
    expect(await run(db.getMcpServer(created.id))).toMatchObject({
      id: created.id,
      name: "Linear",
      toolCount: 18
    })
    expect(await run(db.getMcpServer("missing-mcp"))).toBeUndefined()

    const local = await run(
      db.saveMcpServer({
        args: ["@playwright/mcp@latest"],
        authType: "none",
        command: "npx",
        connectionState: "error",
        detail: "Not installed",
        enabled: false,
        name: "Playwright",
        toolCount: 0,
        transport: "stdio"
      })
    )
    expect(local).toMatchObject({
      args: ["@playwright/mcp@latest"],
      command: "npx",
      detail: "Not installed",
      enabled: false
    })
    expect(local.url).toBeUndefined()
    expect(local.oauthScope).toBeUndefined()
    expect(local.secretCipher).toBeUndefined()
    expect((await run(db.resolveMcpServers())).map((server) => server.id)).toEqual([
      created.id,
      local.id
    ])

    const project = await run(db.createProject({ folderPath: "/tmp/mcp-scope" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Scoped" })
    )
    await run(db.setProjectMcpEnabled(project.id, created.id, false))
    expect((await run(db.resolveMcpServers(project.id)))[0]?.enabled).toBe(false)
    await run(db.setProjectMcpEnabled(project.id, created.id, true))
    await run(db.setSessionMcpEnabled(session.id, created.id, false))
    expect((await run(db.resolveMcpServers(project.id, session.id)))[0]?.enabled).toBe(false)
    await run(db.setSessionMcpEnabled(session.id, created.id, true))
    expect((await run(db.resolveMcpServers(project.id, session.id)))[0]?.enabled).toBe(true)

    await run(db.deleteMcpServer(created.id))
    await run(db.deleteMcpServer(local.id))
    expect(await run(db.listMcpServers)).toEqual([])
    await Effect.runPromise(db.close)
  })

  it("treats a folder as one project per server: idempotent creates and id merges", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const original = await run(db.createProject({ folderPath: "/tmp/duplicate" }))

    // Same folder, no explicit id → the existing project comes back.
    const again = await run(db.createProject({ folderPath: "/tmp/duplicate" }))
    expect(again.id).toBe(original.id)

    // Same id → idempotent.
    const byId = await run(db.createProject({ folderPath: "/tmp/other", id: original.id }))
    expect(byId.id).toBe(original.id)

    // Same folder under a NEW explicit id → the old project merges into it,
    // sessions and all — no unique-constraint failure.
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: original.id, title: "Kept" })
    )
    const merged = await run(
      db.createProject({
        folderPath: "/tmp/duplicate",
        id: "client-id-2",
        isArchived: true,
        name: "merged",
        origin: "imported",
        symbolName: "shippingbox"
      })
    )
    expect(merged.id).toBe("client-id-2")
    expect(merged.isArchived).toBe(true)
    expect(merged.name).toBe("merged")

    // Merge again with a bare request — defaults apply on the merge path too.
    const remerged = await run(
      db.createProject({ folderPath: "/tmp/duplicate", id: "client-id-3" })
    )
    expect(remerged.id).toBe("client-id-3")
    expect(remerged.isArchived).toBe(false)
    expect(remerged.name).toBe("duplicate")
    expect(merged.locations[0]?.folderPath).toBe("/tmp/duplicate")
    const projects = await run(db.listProjects)
    expect(projects.map((project) => project.id)).not.toContain(original.id)
    const detail = await run(db.getSessionDetail(session.id))
    expect(detail.session.projectId).toBe("client-id-3")

    // Genuine sqlite failures still surface as tagged errors.
    const failed = await Effect.runPromiseExit(
      db.createSession({ harnessId: "codex", projectId: "missing-project", title: "x" })
    )
    expect(String(failed)).toContain("DatabaseError")
    await Effect.runPromise(db.close)
  })
})

describe("native config safety", () => {
  it("stores one-time backups with first-write-wins semantics", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    expect(await run(db.getNativeConfigBackup("/home/u/.claude.json"))).toBeUndefined()
    await run(
      db.saveNativeConfigBackup({
        backupPath: "/data/backups/abc-.claude.json",
        createdAt: "2026-07-20T00:00:00.000Z",
        filePath: "/home/u/.claude.json"
      })
    )
    // A second save must not replace the original pre-mutation snapshot.
    await run(
      db.saveNativeConfigBackup({
        backupPath: "/data/backups/later.json",
        createdAt: "2026-07-21T00:00:00.000Z",
        filePath: "/home/u/.claude.json"
      })
    )
    expect(await run(db.getNativeConfigBackup("/home/u/.claude.json"))).toEqual({
      backupPath: "/data/backups/abc-.claude.json",
      createdAt: "2026-07-20T00:00:00.000Z",
      filePath: "/home/u/.claude.json"
    })
    await run(db.close)
  })

  it("parks removals and marks them restored", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const removal = await run(
      db.saveNativeMcpRemoval({
        configPath: "/home/u/.claude.json",
        fragment: JSON.stringify({ command: "docs-mcp" }),
        harnessId: "claude-code",
        serverName: "docs"
      })
    )
    expect(removal).toMatchObject({
      configPath: "/home/u/.claude.json",
      fragment: JSON.stringify({ command: "docs-mcp" }),
      harnessId: "claude-code",
      serverName: "docs"
    })
    expect(removal.restoredAt).toBeUndefined()

    expect(await run(db.listNativeMcpRemovals())).toHaveLength(1)
    await run(db.markNativeMcpRemovalRestored(removal.id))
    // Restored entries drop out of the default listing but stay in history.
    expect(await run(db.listNativeMcpRemovals())).toHaveLength(0)
    const all = await run(db.listNativeMcpRemovals(true))
    expect(all).toHaveLength(1)
    expect(all[0]?.restoredAt).toBeDefined()
    await run(db.close)
  })

  // UUIDs are case-insensitive identifiers, but Swift clients render them
  // uppercase while Node renders them lowercase. A case-only difference must
  // never split one chat into two rows (the duplicate-sidebar-entries bug).
  it("canonicalizes session ids to lowercase and matches either case", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ name: "Case", folderPath: "/tmp/case" }))
    const upper = "AB12CD34-EF56-4789-A012-3456789ABCDE"
    const lower = upper.toLowerCase()

    const created = await run(
      db.createSession({ id: upper, projectId: project.id.toUpperCase(), harnessId: "codex" })
    )
    expect(created.id).toBe(lower)
    expect(created.projectId).toBe(project.id)

    // Reads and writes resolve the same row regardless of the caller's casing.
    expect((await run(db.getSessionSummary(upper))).id).toBe(lower)
    const renamed = await run(db.updateSession(upper, { title: "Renamed" }))
    expect(renamed.title).toBe("Renamed")
    expect(await run(db.listSessions)).toHaveLength(1)

    const queued = await run(db.createPromptQueueItem(upper, "hello", []))
    expect(await run(db.listPromptQueue(lower))).toMatchObject([{ id: queued.id, text: "hello" }])

    await run(db.deleteSession(upper))
    expect(await run(db.listSessions)).toHaveLength(0)
    await run(db.close)
  })

  it("merges case-twin sessions when the canonical ids migration runs", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ name: "Twins", folderPath: "/tmp/twins" }))
    await run(db.close)

    // Recreate the pre-migration damage directly: a remotely created
    // lowercase session with a real transcript, an uppercase phantom fork of
    // it (opened but never prompted), a second pair where both twins were
    // prompted and genuinely forked, and a third pair where neither twin was
    // prompted.
    const lowerA = "aaaaaaaa-1111-4111-8111-111111111111"
    const upperA = lowerA.toUpperCase()
    const lowerB = "bbbbbbbb-2222-4222-8222-222222222222"
    const upperB = lowerB.toUpperCase()
    const lowerC = "cccccccc-3333-4333-8333-333333333333"
    const upperC = lowerC.toUpperCase()
    const sqlite = new Database(filename)
    const insertSession = sqlite.prepare(
      `insert into sessions (id, project_id, server_id, harness_id, title, origin, is_archived, created_at, updated_at)
       values (?, ?, 'local', 'codex', ?, 'codevisor', 0, ?, ?)`
    )
    insertSession.run(
      lowerA,
      project.id,
      "Original A",
      "2026-07-01T00:00:00.000Z",
      "2026-07-01T01:00:00.000Z"
    )
    insertSession.run(
      upperA,
      project.id,
      "Phantom A",
      "2026-07-02T00:00:00.000Z",
      "2026-07-02T01:00:00.000Z"
    )
    insertSession.run(
      lowerB,
      project.id,
      "Original B",
      "2026-07-03T00:00:00.000Z",
      "2026-07-03T02:00:00.000Z"
    )
    insertSession.run(
      upperB,
      project.id,
      "Fork B",
      "2026-07-03T00:30:00.000Z",
      "2026-07-03T01:00:00.000Z"
    )
    insertSession.run(
      lowerC,
      project.id,
      "Older C",
      "2026-07-04T00:00:00.000Z",
      "2026-07-04T01:00:00.000Z"
    )
    insertSession.run(
      upperC,
      project.id,
      "Newer C",
      "2026-07-04T00:30:00.000Z",
      "2026-07-04T02:00:00.000Z"
    )
    const insertChatItem = sqlite.prepare(
      `insert into chat_items (id, session_id, position, role, status, created_at, updated_at)
       values (?, ?, 0, 'user', 'complete', '2026-07-01T00:01:00.000Z', '2026-07-01T00:01:00.000Z')`
    )
    insertChatItem.run("item-a", lowerA)
    insertChatItem.run("item-b-original", lowerB)
    insertChatItem.run("item-b-fork", upperB)
    const insertChatText = sqlite.prepare(
      `insert into chat_parts (id, item_id, position, kind, text, revision)
       values (?, ?, 0, 'text', ?, 1)`
    )
    insertChatText.run("part-a", "item-a", "prompt A")
    insertChatText.run("part-b-original", "item-b-original", "original prompt B")
    insertChatText.run("part-b-fork", "item-b-fork", "fork prompt B")
    // Re-arm the canonicalization migration so reopening the database runs it
    // against the twin rows above.
    sqlite.prepare("delete from schema_migrations where id = 30").run()
    sqlite.close()

    const reopened = await run(makeDatabase({ filename, serverId: "local" }))
    const sessions = await run(reopened.listSessions)

    // Pair A: the unprompted uppercase phantom was deleted outright.
    const pairA = sessions.filter((session) => session.id.toLowerCase() === lowerA)
    expect(pairA).toHaveLength(1)
    expect(pairA[0]).toMatchObject({ id: lowerA, title: "Original A", isArchived: false })

    // Pair B: both twins were prompted, so the most recently active twin
    // keeps the canonical id and the fork survives archived under a fresh
    // lowercase id with its transcript intact.
    const canonicalB = sessions.find((session) => session.id === lowerB)
    expect(canonicalB).toMatchObject({ title: "Original B", isArchived: false })
    const forkB = sessions.find((session) => session.title === "Fork B" && session.id !== lowerB)
    expect(forkB).toBeDefined()
    expect(forkB?.id).toBe(forkB?.id.toLowerCase())
    expect(forkB?.isArchived).toBe(true)
    const forkDetail = await run(reopened.getSessionDetail(forkB!.id))
    expect(forkDetail.conversation).toHaveLength(1)

    // Pair C: neither twin has a transcript, so the most recently active row
    // wins the canonical id and the older phantom is discarded.
    const pairC = sessions.filter((session) => session.id.toLowerCase() === lowerC)
    expect(pairC).toHaveLength(1)
    expect(pairC[0]).toMatchObject({ id: lowerC, title: "Newer C", isArchived: false })

    // No case-twins remain anywhere, and ids are canonically lowercase.
    expect(sessions).toHaveLength(4)
    for (const session of sessions) {
      expect(session.id).toBe(session.id.toLowerCase())
    }
    await run(reopened.close)
  })
})
