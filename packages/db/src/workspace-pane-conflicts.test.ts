import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const seed = async () => {
  const config = { filename: tempDatabase(), serverId: "local" }
  const db = await run(makeDatabase(config))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/pane-conflicts" }))
  const workspace = (name: string) =>
    run(db.upsertWorkspace({ projectId: project.id, name, hasCustomName: false }))
  const source = await workspace("Source")
  const target = await workspace("Target")
  const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  await run(db.setSessionWorkspace(session.id, source.id))
  return { config, db, source, target, session }
}
describe("workspace pane conflicts", () => {
  it("deletes the source pane when a resource moves through an explicit pane", async () => {
    const { db, target, session } = await seed()
    const moved = await run(
      db.upsertWorkspacePane(target.id, {
        id: "explicit-pane",
        providerId: "codevisor",
        paneType: "chat",
        title: "Moved chat",
        resourceKind: "session",
        resourceId: session.id
      })
    )
    expect(moved).toMatchObject({ workspaceId: target.id, resourceId: session.id })
    expect(await run(db.listWorkspacePanes)).toEqual([
      expect.objectContaining({
        id: "explicit-pane",
        workspaceId: target.id,
        resourceId: session.id
      })
    ])
    await expect(run(db.deleteWorkspacePane("missing", "missing"))).rejects.toThrow(
      /Workspace not found/
    )
  })
  it.each(["upsertWorkspacePane", "updateWorkspacePane", "promoteWorkspacePaneToSession"] as const)(
    "rolls back conflict deletion and membership when %s aborts its pane write",
    async (operation) => {
      const { config, db, source, target, session } = await seed()
      const request = {
        id: "target-pane",
        providerId: "codevisor",
        paneType: "chat",
        title: "Placeholder",
        metadata: '{"original":true}'
      }
      await run(db.upsertWorkspacePane(target.id, request))
      const original = await run(db.listWorkspacePanes)
      const sqlite = new Database(config.filename)
      onTestFinished(() => {
        sqlite.close()
      })
      sqlite.exec(`create trigger abort_pane_write before ${operation === "upsertWorkspacePane" ? "insert" : "update"} on workspace_panes
        when new.id = 'target-pane' begin
          select case when exists (select 1 from workspace_panes where id = '${session.id}')
            then raise(abort, 'conflict was not deleted') end;
          select raise(abort, 'pane write aborted');
        end`)
      const resource = { resourceKind: "session", resourceId: session.id }
      const effect =
        operation === "upsertWorkspacePane"
          ? db.upsertWorkspacePane(target.id, { ...request, ...resource })
          : operation === "updateWorkspacePane"
            ? db.updateWorkspacePane(target.id, request.id, resource)
            : db.promoteWorkspacePaneToSession(target.id, request.id, session.id, "Converted")
      expect(await Effect.runPromise(Effect.flip(effect))).toMatchObject({
        _tag: "DatabaseError",
        operation,
        message: "pane write aborted"
      })
      expect(await run(db.listWorkspacePanes)).toEqual(original)
      expect((await run(db.getSessionSummary(session.id))).workspaceId).toBe(source.id)
      await run(db.close)
      const reopened = await run(makeDatabase(config))
      onTestFinished(() => run(reopened.close))
      expect(await run(reopened.listWorkspacePanes)).toEqual(original)
      expect((await run(reopened.getSessionSummary(session.id))).workspaceId).toBe(source.id)
    }
  )

  it("keeps a chat's tab slot when a new pane id replaces its pane", async () => {
    const { db, source, session } = await seed()
    await run(
      db.upsertWorkspacePane(source.id, {
        id: "terminal-pane",
        providerId: "codevisor",
        paneType: "terminal",
        title: "Terminal"
      })
    )
    const [original] = await run(db.listWorkspacePanes)

    // A device that has not loaded the chat's tab opens it under a fresh id.
    await run(
      db.upsertWorkspacePane(source.id, {
        id: "fresh-pane",
        providerId: "codevisor",
        paneType: "chat",
        title: "Chat",
        resourceKind: "session",
        resourceId: session.id
      })
    )

    expect(await run(db.listWorkspacePanes)).toEqual([
      expect.objectContaining({ id: "fresh-pane", position: original?.position }),
      expect.objectContaining({ id: "terminal-pane" })
    ])
  })
})
