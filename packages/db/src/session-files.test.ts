import { existsSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import type { FileMetadata } from "@codevisor/api"
import Database from "better-sqlite3"
import { afterEach, describe, expect, it, onTestFinished } from "vitest"

import { makeAttachmentStore, type AttachmentStore } from "./attachment-store.js"
import { removeUnreferencedAttachments } from "./attachment-sweep.js"
import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { memoryDatabase, run, tempDatabase } from "./test-support.js"

const directories: Array<string> = []

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

const temporaryStore = (): AttachmentStore => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-session-files-"))
  directories.push(directory)
  return makeAttachmentStore(directory)
}

const storeFile = async (
  db: CodevisorDatabaseService,
  store: AttachmentStore,
  id: string
): Promise<FileMetadata> => {
  const stored = await store.put(Buffer.from(`bytes of ${id}`))
  return await run(
    db.createDiskFile({
      id,
      name: `${id}.png`,
      mimeType: "image/png",
      sizeBytes: stored.sizeBytes,
      sha256: stored.sha256,
      kind: "image",
      createdAt: "2026-10-26T00:00:00.000Z"
    })
  )
}

const rewindToV78 = (filename: string): void => {
  const sqlite = new Database(filename)
  try {
    sqlite.exec(`
      drop table session_files;
      alter table files drop column purge_with_chats;
      delete from schema_migrations where id = 79;
    `)
  } finally {
    sqlite.close()
  }
}

const sendFiles = (
  db: CodevisorDatabaseService,
  sessionId: string,
  files: ReadonlyArray<FileMetadata>
) =>
  run(
    db.appendEvent("session.output", sessionId, {
      sessionUpdate: "assistant_message_finalized",
      markdown: "Here you go",
      attachments: files.map((file) => ({ fileId: file.id, name: file.name }))
    })
  )

describe("chat-owned files", () => {
  it("purges the files only a deleted chat used and keeps the rest", async () => {
    const { db, project, session } = await memoryDatabase()
    const other = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const store = temporaryStore()
    const own = await storeFile(db, store, "own")
    const shared = await storeFile(db, store, "shared")
    const draft = await storeFile(db, store, "draft")
    await sendFiles(db, session.id, [own, shared])
    await sendFiles(db, other.id, [shared])

    await run(db.deleteSession(session.id))

    expect(await run(db.getFileMetadata(own.id))).toBeUndefined()
    expect(await run(db.getFileMetadata(shared.id))).toEqual(shared)
    expect(await run(db.getFileMetadata(draft.id))).toEqual(draft)
  })

  it("never purges a file stored before chats owned their files", async () => {
    const filename = tempDatabase()
    const store = temporaryStore()
    const before = await run(makeDatabase({ filename, serverId: "local" }))
    const old = await storeFile(before, store, "old")
    await run(before.close)
    rewindToV78(filename)
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    onTestFinished(() => run(db.close))
    const project = await run(db.createProject({ folderPath: "/tmp/session-files-legacy" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const fresh = await storeFile(db, store, "fresh")
    await sendFiles(db, session.id, [old, fresh])

    await run(db.deleteSession(session.id))

    expect(await run(db.getFileMetadata(old.id))).toEqual(old)
    expect(await run(db.getFileMetadata(fresh.id))).toBeUndefined()
  })

  it("removes stored bytes and named copies no file refers to", async () => {
    const { db, session } = await memoryDatabase()
    const store = temporaryStore()
    const kept = await storeFile(db, store, "kept")
    const purged = await storeFile(db, store, "purged")
    const keptCopy = await store.materialize(kept)
    const purgedCopy = await store.materialize(purged)
    await sendFiles(db, session.id, [purged])
    await run(db.deleteSession(session.id))

    await removeUnreferencedAttachments(db, store)

    expect(existsSync(store.objectPath(kept.sha256))).toBe(true)
    expect(existsSync(keptCopy)).toBe(true)
    expect(existsSync(store.objectPath(purged.sha256))).toBe(false)
    expect(existsSync(dirname(purgedCopy))).toBe(false)
    await expect(removeUnreferencedAttachments(db, temporaryStore())).resolves.toBeUndefined()
  })
})
