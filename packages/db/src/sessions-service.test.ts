import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase, worktreePath } from "./index.js"
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
})
