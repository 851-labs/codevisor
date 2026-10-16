import Database from "better-sqlite3"
import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

let clock = 0
const tick = () => vi.setSystemTime(new Date(Date.UTC(2026, 9, 15, 12, 0, ++clock)))

beforeEach(() => {
  clock = 0
  vi.useFakeTimers({ toFake: ["Date"] })
})

afterEach(() => {
  vi.useRealTimers()
})

const seedWorkspace = async (db: CodevisorDatabaseService, name: string) => {
  const project = await run(db.createProject({ folderPath: `/tmp/file-changes-${name}` }))
  const workspace = await run(
    db.upsertWorkspace({ projectId: project.id, name, hasCustomName: false })
  )
  const session = async () => {
    const created = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(created.id, workspace.id))
    await run(db.appendEvent("session.updated", created.id, { turnState: "started" }))
    return created
  }
  return { workspace, session }
}

const output = (db: CodevisorDatabaseService, sessionId: string, payload: unknown) => {
  tick()
  return run(db.appendEvent("session.output", sessionId, payload))
}

const edit = (
  toolCallId: string,
  fields: Readonly<Record<string, unknown>>,
  update = "tool_call_update"
) => ({ sessionUpdate: update, toolCallId, kind: "edit", ...fields })

describe("workspace file edits", () => {
  it("lists completed edits per file with the final counts, newest first", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const work = await seedWorkspace(db, "work")
      const other = await seedWorkspace(db, "other")
      const first = await work.session()
      const second = await work.session()
      const elsewhere = await other.session()

      await output(
        db,
        first.id,
        edit("claude-write", { status: "pending", title: "Write" }, "tool_call")
      )
      await output(
        db,
        first.id,
        edit("claude-write", {
          status: "in_progress",
          diffStats: [{ path: "/repo/Sources/App.swift", added: 3, removed: 0 }]
        })
      )
      await output(
        db,
        first.id,
        edit("claude-write", {
          diffStats: [{ path: "/repo/Sources/App.swift", added: 40, removed: 2 }]
        })
      )
      await output(db, first.id, edit("claude-write", { status: "completed" }))

      await output(
        db,
        second.id,
        edit(
          "codex-patch",
          {
            status: "in_progress",
            diffStats: [
              { path: "/repo/README.md", added: 5, removed: 1 },
              { path: "/repo/Sources/App.swift", added: 1, removed: 1 }
            ]
          },
          "tool_call"
        )
      )
      await output(
        db,
        second.id,
        edit("codex-patch", {
          status: "completed",
          diffStats: [
            { path: "/repo/README.md", added: 6, removed: 1 },
            { path: "/repo/Sources/App.swift", added: 1, removed: 1 }
          ]
        })
      )
      await output(
        db,
        second.id,
        edit("codex-rejected", {
          status: "failed",
          diffStats: [{ path: "/repo/Rejected.swift", added: 9, removed: 0 }]
        })
      )
      await output(
        db,
        second.id,
        edit("codex-odd", {
          status: "completed",
          diffStats: [
            "not a stat",
            { path: "", added: 1, removed: 1 },
            { path: "/repo/odd.txt", added: Number.NaN, removed: -4 },
            { path: "/repo/odd.txt", added: 2.6, removed: "3" }
          ]
        })
      )
      await output(db, second.id, {
        sessionUpdate: "tool_call_update",
        status: "completed",
        diffStats: [{ path: "/repo/anonymous.txt", added: 1, removed: 0 }]
      })
      await output(db, second.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "Updated the README." }
      })
      await output(
        db,
        elsewhere.id,
        edit("foreign", {
          status: "completed",
          diffStats: [{ path: "/elsewhere/file.ts", added: 1, removed: 0 }]
        })
      )

      const edits = await run(db.listWorkspaceFileEdits(work.workspace.id, 10))
      expect(edits.map((file) => [file.path, file.added, file.removed, file.sessionId])).toEqual([
        ["/repo/odd.txt", 3, 0, second.id],
        ["/repo/README.md", 6, 1, second.id],
        ["/repo/Sources/App.swift", 41, 3, second.id]
      ])
      expect(edits[0]!.changedAt > edits[1]!.changedAt).toBe(true)
      expect(edits[1]!.changedAt).toBe(edits[2]!.changedAt)

      expect(await run(db.listWorkspaceFileEdits(work.workspace.id.toUpperCase(), 1))).toEqual([
        edits[0]
      ])
      expect(await run(db.listWorkspaceFileEdits(other.workspace.id, 10))).toMatchObject([
        { path: "/elsewhere/file.ts", sessionId: elsewhere.id }
      ])
    } finally {
      await run(db.close)
    }
  })

  it("backfills edits recorded before file changes were tracked", async () => {
    const filename = tempDatabase()
    const current = await run(makeDatabase({ filename, serverId: "local" }))
    const work = await seedWorkspace(current, "upgrade")
    const session = await work.session()
    await output(
      current,
      session.id,
      edit("upgrade-edit", {
        status: "completed",
        diffStats: [{ path: "/repo/upgrade.ts", added: 7, removed: 2 }]
      })
    )
    await output(
      current,
      session.id,
      edit("upgrade-running", {
        status: "in_progress",
        diffStats: [{ path: "/repo/running.ts", added: 1, removed: 0 }]
      })
    )
    await Effect.runPromise(current.close)

    const legacy = new Database(filename)
    try {
      legacy.exec(`
      drop table chat_item_file_changes;
      delete from schema_migrations where id = 63;
    `)
    } finally {
      legacy.close()
    }

    const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect(await run(upgraded.listWorkspaceFileEdits(work.workspace.id, 10))).toMatchObject([
        { path: "/repo/upgrade.ts", added: 7, removed: 2, sessionId: session.id }
      ])
    } finally {
      await run(upgraded.close)
    }
  })
})
