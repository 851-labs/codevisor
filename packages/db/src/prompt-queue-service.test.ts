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

  it("keeps a queued prompt's attachments through a text edit and replaces them when given", async () => {
    const { db, session } = await queueFixture()
    const photo = {
      fileId: "file-photo",
      name: "photo.png",
      mimeType: "image/png",
      sizeBytes: 10,
      kind: "image" as const
    }
    const notes = {
      fileId: "file-notes",
      name: "notes.txt",
      mimeType: "text/plain",
      sizeBytes: 5,
      kind: "file" as const
    }
    const item = await run(db.createPromptQueueItem(session.id, "look at this", [photo]))

    const retitled = await run(db.updatePromptQueueItem(session.id, item.id, "look at this now"))
    const swapped = await run(db.updatePromptQueueItem(session.id, item.id, "notes", [notes]))
    const cleared = await run(db.updatePromptQueueItem(session.id, item.id, "no files", []))

    expect(retitled.attachments).toEqual([photo])
    expect(swapped.attachments).toEqual([notes])
    expect(cleared.attachments).toBeUndefined()
  })
})
