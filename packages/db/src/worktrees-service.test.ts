import { Effect } from "effect"
import { homedir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { DatabaseError, makeDatabase, worktreePath } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
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
})
