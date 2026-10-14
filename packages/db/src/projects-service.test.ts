import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("persists and clears a project's worktree base branch", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
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
    } finally {
      await run(db.close)
    }
  })

  it("persists and clears a project's default run location", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/run-location" }))
      expect(project.defaultRunLocation).toBeUndefined()

      await run(db.updateProject(project.id, { defaultRunLocation: "newWorktree" }))
      expect((await run(db.listProjects))[0]?.defaultRunLocation).toBe("newWorktree")

      const rebased = await run(
        db.updateProject(project.id, { worktreeBase: { remote: "origin", branch: "develop" } })
      )
      expect(rebased.defaultRunLocation).toBe("newWorktree")
      expect(
        (await run(db.updateProject(project.id, { defaultRunLocation: null }))).defaultRunLocation
      ).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })

  it("round-trips the git remote a project was cloned from", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
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
      const plain = await run(db.createProject({ folderPath: "/tmp/plain-dir" }))
      expect(plain.repoUrl).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })

  it("treats a folder as one project per server: idempotent creates and id merges", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const original = await run(db.createProject({ folderPath: "/tmp/duplicate" }))

      const again = await run(db.createProject({ folderPath: "/tmp/duplicate" }))
      expect(again.id).toBe(original.id)

      const byId = await run(db.createProject({ folderPath: "/tmp/other", id: original.id }))
      expect(byId.id).toBe(original.id)

      const session = await run(
        db.createSession({ harnessId: "codex", projectId: original.id, title: "Kept" })
      )
      const merged = await run(
        db.createProject({
          folderPath: "/tmp/duplicate",
          id: "client-id-2",
          name: "merged",
          origin: "imported"
        })
      )
      expect(merged.id).toBe("client-id-2")
      expect(merged.name).toBe("merged")

      const remerged = await run(
        db.createProject({ folderPath: "/tmp/duplicate", id: "client-id-3" })
      )
      expect(remerged.id).toBe("client-id-3")
      expect(remerged.name).toBe("duplicate")
      expect(merged.locations[0]?.folderPath).toBe("/tmp/duplicate")
      const projects = await run(db.listProjects)
      expect(projects.map((project) => project.id)).not.toContain(original.id)
      const detail = await run(db.getSessionDetail(session.id))
      expect(detail.session.projectId).toBe("client-id-3")

      const failed = await Effect.runPromiseExit(
        db.createSession({ harnessId: "codex", projectId: "missing-project", title: "x" })
      )
      expect(String(failed)).toContain("DatabaseError")
    } finally {
      await Effect.runPromise(db.close)
    }
  })
})
