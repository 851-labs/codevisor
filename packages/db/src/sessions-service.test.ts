import type { Project, SessionSummary } from "@codevisor/api"
import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeDatabase, worktreePath } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("re-homes a session to another project, dropping stale worktree names", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
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

      const moved = await run(db.updateSession(session.id, { projectId: destination.id }))
      expect(moved.projectId).toBe(destination.id)
      expect(moved.worktreeName).toBeUndefined()
      expect(moved.cwd).toBe("/tmp/move-destination")

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
    } finally {
      await run(db.close)
    }
  })

  it("persists the resolved config selections for each session", async () => {
    const filename = tempDatabase()
    let session: SessionSummary
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/session-config" }))
      session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

      expect((await run(db.getSessionSummary(session.id))).configSelections).toBeUndefined()
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
      await run(
        db.replaceSessionConfigSelections(
          session.id,
          { model: "gpt-5.6-sol", reasoning: "high", speed: "standard" },
          { model: "gpt-5.6-sol" }
        )
      )
      await run(
        db.replaceSessionConfigSelections(session.id, {
          model: "gpt-5.6-sol",
          reasoning: "high",
          speed: "standard"
        })
      )
      expect((await run(db.getSessionSummary(session.id))).unavailableConfigSelections).toEqual({
        model: "gpt-5.6-sol"
      })
    } finally {
      await Effect.runPromise(db.close)
    }

    const reopened = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect((await run(reopened.getSessionSummary(session.id))).configSelections).toEqual({
        model: "gpt-5.6-sol",
        reasoning: "high",
        speed: "standard"
      })
      await run(reopened.replaceSessionConfigSelections(session.id, { model: "gpt-5.6-sol" }, {}))
      expect(
        (await run(reopened.getSessionSummary(session.id))).unavailableConfigSelections
      ).toBeUndefined()
    } finally {
      await Effect.runPromise(reopened.close)
    }

    const sqlite = new Database(filename)
    try {
      sqlite
        .prepare("update sessions set config_selections = ? where id = ?")
        .run("not-json", session.id)
    } finally {
      sqlite.close()
    }
    const recovered = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect((await run(recovered.getSessionSummary(session.id))).configSelections).toBeUndefined()
    } finally {
      await Effect.runPromise(recovered.close)
    }
  })

  it("omits session cwd when the project has no folder on this server", async () => {
    const filename = tempDatabase()
    let project: Project
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      project = await run(db.createProject({ folderPath: "/tmp/elsewhere" }))
      await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    } finally {
      await Effect.runPromise(db.close)
    }

    const sqlite = new Database(filename)
    try {
      sqlite.prepare("delete from project_locations where project_id = ?").run(project.id)
    } finally {
      sqlite.close()
    }
    const reread = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const sessions = await run(reread.listSessions)
      expect(sessions[0]?.cwd).toBeUndefined()
    } finally {
      await Effect.runPromise(reread.close)
    }
  })
})
