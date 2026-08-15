import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("stores file blobs and threads attachments through queue and conversation rows", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/attachments" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
    const metadata = await run(db.createFile("shot.png", "image/png", "image", bytes))
    expect(metadata).toMatchObject({
      name: "shot.png",
      mimeType: "image/png",
      sizeBytes: bytes.byteLength,
      kind: "image"
    })
    expect(metadata.sha256).toHaveLength(64)

    const stored = await run(db.getFile(metadata.id))
    expect(stored?.metadata).toEqual(metadata)
    expect(stored?.data.equals(bytes)).toBe(true)
    expect(await run(db.getFileMetadata(metadata.id))).toEqual(metadata)
    expect(await run(db.getFile("missing-file"))).toBeUndefined()
    expect(await run(db.getFileMetadata("missing-file"))).toBeUndefined()

    const ref = {
      fileId: metadata.id,
      name: metadata.name,
      mimeType: metadata.mimeType,
      sizeBytes: metadata.sizeBytes,
      kind: metadata.kind
    }
    const queued = await run(db.createPromptQueueItem(session.id, "with file", [ref]))
    expect(queued.attachments).toEqual([ref])
    expect((await run(db.listPromptQueue(session.id)))[0]?.attachments).toEqual([ref])
    expect(await run(db.claimPromptQueueItem(session.id))).toMatchObject({
      text: "with file",
      attachments: [ref]
    })
    await run(db.completePromptQueueItem(session.id, queued.id))
    const queuedPlain = await run(db.createPromptQueueItem(session.id, "no file", []))
    expect(queuedPlain.attachments).toBeUndefined()
    expect(await run(db.claimPromptQueueItem(session.id))).toMatchObject({ text: "no file" })

    await run(
      db.appendConversationItem(session.id, "user", undefined, "look at this", false, [ref])
    )
    await run(db.appendConversationItem(session.id, "assistant", undefined, "nice", false))
    const detail = await run(db.getSessionDetail(session.id))
    expect(detail.conversation[0]?.attachments).toEqual([ref])
    expect(detail.conversation[1]?.attachments).toBeUndefined()

    // A literal empty JSON array in the canonical item reads back as "no attachments".
    const sqlite = new Database(filename)
    sqlite.prepare("update chat_items set attachments = '[]' where session_id = ?").run(session.id)
    sqlite.close()
    const emptied = await run(db.getSessionDetail(session.id))
    expect(emptied.conversation[0]?.attachments).toBeUndefined()

    await Effect.runPromise(db.close)
  })
})
