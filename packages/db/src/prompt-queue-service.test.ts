import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run } from "./test-support.js"

const queueFixture = async () => {
  const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/prompt-queue" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  return { db, session }
}

describe("prompt queue", () => {
  it("remembers which prompts the system queued", async () => {
    const { db, session } = await queueFixture()

    const fromUser = await run(db.createPromptQueueItem(session.id, "from the user"))
    const fromSystem = await run(
      db.createPromptQueueItem(session.id, "child finished", [], undefined, undefined, "system")
    )

    expect(fromUser.origin).toBeUndefined()
    expect(fromSystem.origin).toBe("system")
    expect((await run(db.listPromptQueue(session.id))).map((item) => item.origin)).toEqual([
      undefined,
      "system"
    ])
  })

  it("puts a released prompt back in line to be claimed again", async () => {
    const { db, session } = await queueFixture()
    const item = await run(db.createPromptQueueItem(session.id, "steer me"))

    expect(await run(db.claimPromptQueueItem(session.id))).toMatchObject({ id: item.id })
    expect(await run(db.claimPromptQueueItem(session.id))).toBeUndefined()
    await run(db.releasePromptQueueItem(session.id, item.id))

    expect(await run(db.claimPromptQueueItem(session.id))).toMatchObject({ id: item.id })
  })

  it("claims a chosen prompt out of line without disturbing the others", async () => {
    const { db, session } = await queueFixture()
    const first = await run(db.createPromptQueueItem(session.id, "first"))
    const second = await run(db.createPromptQueueItem(session.id, "second"))

    expect(await run(db.claimPromptQueueItem(session.id, second.id))).toMatchObject({
      id: second.id
    })
    expect(await run(db.claimPromptQueueItem(session.id, second.id))).toBeUndefined()
    expect(await run(db.listPromptQueue(session.id))).toMatchObject([{ id: first.id }])
  })
})
