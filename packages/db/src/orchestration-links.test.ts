import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("orchestration links and labels", () => {
  it("persists a child session's parent and labels, and replaces labels only when asked", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/orchestration-sessions" }))
      const parent = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const child = await run(
        db.createSession({
          projectId: project.id,
          harnessId: "codex",
          parentSessionId: parent.id.toUpperCase(),
          labels: { issue: "851-12", role: "worker" }
        })
      )
      expect(child).toMatchObject({
        parentSessionId: parent.id,
        labels: { issue: "851-12", role: "worker" }
      })
      expect(parent.parentSessionId).toBeUndefined()
      expect(parent.labels).toBeUndefined()

      expect((await run(db.updateSession(child.id, { title: "Renamed" }))).labels).toEqual({
        issue: "851-12",
        role: "worker"
      })
      expect((await run(db.updateSession(child.id, { labels: { role: "done" } }))).labels).toEqual({
        role: "done"
      })
      expect((await run(db.updateSession(child.id, { labels: {} }))).labels).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })

  it("keeps workspace labels across native re-upserts that omit them", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/orchestration-workspaces" }))
      const base = { projectId: project.id, name: "feature", hasCustomName: false }
      const workspace = await run(db.upsertWorkspace({ ...base, labels: { batch: "a" } }))
      expect(workspace.labels).toEqual({ batch: "a" })

      expect(
        (await run(db.upsertWorkspace({ ...base, id: workspace.id, name: "renamed" }))).labels
      ).toEqual({ batch: "a" })
      expect(
        (await run(db.upsertWorkspace({ ...base, id: workspace.id, labels: { batch: "b" } })))
          .labels
      ).toEqual({ batch: "b" })
      expect((await run(db.updateWorkspace(workspace.id, { name: "again" }))).labels).toEqual({
        batch: "b"
      })
      expect((await run(db.updateWorkspace(workspace.id, { labels: {} }))).labels).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })

  it("reads hand-edited labels leniently instead of failing the listing", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/orchestration-corrupt" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const cases: ReadonlyArray<readonly [string, Record<string, string> | undefined]> = [
        ["{not json", undefined],
        ["null", undefined],
        ['["a"]', undefined],
        ['{"n": 1}', undefined],
        ['{"n": 1, "kept": "yes"}', { kept: "yes" }]
      ]
      for (const [raw, expected] of cases) {
        const sqlite = new Database(filename)
        try {
          sqlite.prepare("update sessions set labels = ? where id = ?").run(raw, session.id)
        } finally {
          sqlite.close()
        }
        const listed = (await run(db.listSessions)).find((candidate) => candidate.id === session.id)
        expect(listed?.labels, raw).toEqual(expected)
      }
    } finally {
      await run(db.close)
    }
  })
})
