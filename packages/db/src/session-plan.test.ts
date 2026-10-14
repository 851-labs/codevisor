import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { sessionPlanFromRaw } from "./event-payloads.js"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("durable session checklists", () => {
  it("ignores malformed durable checklist JSON", () => {
    expect(sessionPlanFromRaw("{")).toBeUndefined()
  })

  it("persists the latest valid checklist into every reconnect snapshot", async () => {
    const filename = tempDatabase()
    let session: { id: string }
    let completedPlan: { entries: Array<{ content: string; priority: string; status: string }> }
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/session-checklist" }))
      session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const activePlan = {
        entries: [
          { content: "Inspect", priority: "high", status: "completed" },
          { content: "Implement", priority: "medium", status: "in_progress" }
        ]
      }

      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "plan",
          ...activePlan
        })
      )
      expect((await run(db.getTranscriptPage(session.id, undefined, 8))).sessionPlan).toEqual(
        activePlan
      )
      expect((await run(db.getSessionDetail(session.id))).sessionPlan).toEqual(activePlan)

      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "plan",
          entries: [{ content: "Broken", priority: "urgent", status: "pending" }]
        })
      )
      expect((await run(db.getTranscriptPage(session.id, undefined, 8))).sessionPlan).toEqual(
        activePlan
      )

      completedPlan = {
        entries: [{ content: "Ship", priority: "low", status: "completed" }]
      }
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "plan",
          ...completedPlan
        })
      )
      expect((await run(db.getTranscriptPage(session.id, undefined, 8))).sessionPlan).toEqual(
        completedPlan
      )
    } finally {
      await Effect.runPromise(db.close)
    }

    const reopened = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect((await run(reopened.getTranscriptPage(session.id, undefined, 8))).sessionPlan).toEqual(
        completedPlan
      )
    } finally {
      await Effect.runPromise(reopened.close)
    }
  })
})
