import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("persists and clears a project's worktree base branch", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/configured-base" }))
    expect(project.worktreeBase).toBeUndefined()

    const configured = await run(
      db.updateProject(project.id, {
        worktreeBase: { remote: "upstream", branch: "release/next" }
      })
    )
    expect(configured.worktreeBase).toEqual({ remote: "upstream", branch: "release/next" })
    expect((await run(db.listProjects))[0]?.worktreeBase).toEqual({
      remote: "upstream",
      branch: "release/next"
    })

    const renamed = await run(db.updateProject(project.id, { name: "Still configured" }))
    expect(renamed.worktreeBase).toEqual({ remote: "upstream", branch: "release/next" })
    expect(
      (await run(db.updateProject(project.id, { worktreeBase: null }))).worktreeBase
    ).toBeUndefined()
    await run(db.close)
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
