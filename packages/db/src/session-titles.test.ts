import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("session title ownership", () => {
  it("accepts a first-send fallback, then preserves harness titles across stale sync", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/title-test" }))
      const session = await run(
        db.createSession({ projectId: project.id, harnessId: "codex", title: "New Chat" })
      )
      const fallback = { title: "Please fix the login form", titleIntent: "fallback" as const }
      expect((await run(db.updateSession(session.id, fallback))).title).toBe(fallback.title)
      expect(
        (await run(db.updateSessionTitleFromHarness(session.id, "Fix login validation")))?.title
      ).toBe("Fix login validation")
      expect(
        (await run(db.updateSession(session.id, { ...fallback, worktreeName: "work" }))).title
      ).toBe("Fix login validation")
      // A later harness improvement remains eligible: snapshot sync never locks it.
      expect(
        (await run(db.updateSessionTitleFromHarness(session.id, "Validate login input")))?.title
      ).toBe("Validate login input")
      const current = await run(db.getSessionSummary(session.id))
      expect(current.worktreeName).toBe("work")
      expect(current.updatedAt).toBe(session.updatedAt)
    } finally {
      await run(db.close)
    }
  })

  it("an explicit rename wins even if it keeps the same text", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/title-rename" }))
      const session = await run(
        db.createSession({ projectId: project.id, harnessId: "codex", title: "New Chat" })
      )
      await run(db.updateSession(session.id, { title: "New Chat", titleIntent: "rename" }))
      await run(db.updateSession(session.id, { title: "First message", titleIntent: "fallback" }))
      expect(
        await run(db.updateSessionTitleFromHarness(session.id, "Generated title"))
      ).toBeUndefined()
      expect((await run(db.getSessionSummary(session.id))).title).toBe("New Chat")
      // Metadata-only PATCHes must preserve ownership too.
      await run(db.updateSession(session.id, { titleIntent: "rename", worktreeName: "sushi" }))
      expect(
        await run(db.updateSessionTitleFromHarness(session.id, "Another title"))
      ).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })
})
