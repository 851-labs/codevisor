import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run } from "./test-support.js"

const fixture = async () => {
  const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/auto-resume" }))
  const first = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
  const second = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  return { db, first, second }
}

describe("session auto resumes", () => {
  it("lists waiting resumes in check order and replaces a session's resume in place", async () => {
    const { db, first, second } = await fixture()

    await run(
      db.saveAutoResume({
        sessionId: first.id.toUpperCase(),
        harnessId: "claude-code",
        harnessAccountId: "work",
        state: "waiting",
        resetsAt: "2026-10-20T15:00:00.000Z",
        checkAt: "2026-10-20T15:00:30.000Z",
        checks: 0
      })
    )
    await run(
      db.saveAutoResume({
        sessionId: second.id,
        harnessId: "codex",
        state: "waiting",
        checkAt: "2026-10-20T14:05:00.000Z",
        checks: 2
      })
    )

    expect((await run(db.listWaitingAutoResumes)).map((resume) => resume.sessionId)).toEqual([
      second.id,
      first.id
    ])
    expect(await run(db.getAutoResume(first.id))).toEqual({
      sessionId: first.id,
      harnessId: "claude-code",
      harnessAccountId: "work",
      state: "waiting",
      resetsAt: "2026-10-20T15:00:00.000Z",
      checkAt: "2026-10-20T15:00:30.000Z",
      checks: 0
    })

    await run(
      db.saveAutoResume({
        sessionId: second.id,
        harnessId: "codex",
        state: "resuming",
        checkAt: "2026-10-20T14:05:00.000Z",
        checks: 3
      })
    )

    expect((await run(db.listWaitingAutoResumes)).map((resume) => resume.sessionId)).toEqual([
      first.id
    ])
    expect(await run(db.getAutoResume(second.id))).toMatchObject({ state: "resuming", checks: 3 })
  })

  it("forgets a resume once it is deleted or its session is gone", async () => {
    const { db, first, second } = await fixture()
    for (const session of [first, second]) {
      await run(
        db.saveAutoResume({
          sessionId: session.id,
          harnessId: session.harnessId,
          state: "waiting",
          checkAt: "2026-10-20T15:00:00.000Z",
          checks: 0
        })
      )
    }

    expect(await run(db.deleteAutoResume(first.id))).toBe(true)
    expect(await run(db.deleteAutoResume(first.id))).toBe(false)
    expect(await run(db.getAutoResume(first.id))).toBeUndefined()

    await run(db.deleteSession(second.id))

    expect(await run(db.listWaitingAutoResumes)).toEqual([])
  })
})
