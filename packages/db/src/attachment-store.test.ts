import Database from "better-sqlite3"
import { Effect } from "effect"
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  makeAttachmentStore,
  migrateAttachmentBlobs,
  type AttachmentStore
} from "./attachment-store.js"
import { makeDatabase, type CodevisorDatabaseService } from "./index.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)
const directories: Array<string> = []
const databases: Array<CodevisorDatabaseService> = []

const temporaryDirectory = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-attachment-store-"))
  directories.push(directory)
  return directory
}

afterEach(async () => {
  for (const db of databases.splice(0)) await run(db.close)
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

describe("attachment object storage", () => {
  it("upgrades legacy file rows without changing their bytes", async () => {
    const directory = temporaryDirectory()
    const filename = join(directory, "codevisor.sqlite")
    const legacy = await run(makeDatabase({ filename, serverId: "local" }))
    const bytes = Buffer.from("legacy attachment")
    const metadata = await run(legacy.createFile("legacy.txt", "text/plain", "file", bytes))
    await run(legacy.close)

    const sqlite = new Database(filename)
    sqlite.exec(`
      alter table files drop column storage_state;
      delete from schema_migrations where id = 29;
    `)
    sqlite.close()

    const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
    databases.push(upgraded)
    const record = await run(upgraded.getFileStorage(metadata.id))
    expect(record?.storageState).toBe("sqlite")
    expect(record?.data.equals(bytes)).toBe(true)
  })

  it("atomically stores, verifies, and deduplicates content-addressed bytes", async () => {
    const directory = temporaryDirectory()
    const store = makeAttachmentStore(directory)
    const bytes = Buffer.from("same immutable attachment")

    const first = await store.put(bytes)
    const second = await store.put(bytes)

    expect(second.path).toBe(first.path)
    expect(readFileSync(first.path).equals(bytes)).toBe(true)
    expect(await store.verify({ sha256: first.sha256, sizeBytes: bytes.byteLength })).toBe(true)
    expect(readdirSync(join(store.root, "staging"))).toEqual([])
  })

  it("backfills legacy blobs, verifies disk bytes, and only then clears SQLite", async () => {
    const directory = temporaryDirectory()
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "local" })
    )
    databases.push(db)
    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
    const metadata = await run(db.createFile("shot.png", "image/png", "image", bytes))
    const progress: Array<string> = []
    const store = makeAttachmentStore(directory)

    await migrateAttachmentBlobs(db, store, (value) => progress.push(value.state))

    expect(await run(db.fileStorageCounts)).toEqual({ disk: 1, dual: 0, sqlite: 0 })
    expect((await run(db.getFileStorage(metadata.id)))?.data.byteLength).toBe(0)
    expect((await store.read(metadata)).equals(bytes)).toBe(true)
    expect(progress.at(-1)).toBe("completed")
  })

  it("leaves the legacy blob intact when interrupted and resumes idempotently", async () => {
    const directory = temporaryDirectory()
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "local" })
    )
    databases.push(db)
    const bytes = Buffer.from("survives an interrupted migration")
    const metadata = await run(db.createFile("notes.txt", "text/plain", "file", bytes))
    const store = makeAttachmentStore(directory)
    const interrupted: AttachmentStore = {
      ...store,
      put: async (data, expectedSha256) => {
        await store.put(data, expectedSha256)
        throw new Error("simulated process interruption")
      }
    }

    await expect(migrateAttachmentBlobs(db, interrupted)).rejects.toThrow(
      "simulated process interruption"
    )
    const legacy = await run(db.getFileStorage(metadata.id))
    expect(legacy?.storageState).toBe("sqlite")
    expect(legacy?.data.equals(bytes)).toBe(true)

    await migrateAttachmentBlobs(db, store)
    expect((await run(db.getFileStorage(metadata.id)))?.storageState).toBe("disk")
    expect((await store.read(metadata)).equals(bytes)).toBe(true)
  })

  it("repairs a corrupt dual object from the retained blob before cutover", async () => {
    const directory = temporaryDirectory()
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "local" })
    )
    databases.push(db)
    const bytes = Buffer.from("authoritative legacy bytes")
    const metadata = await run(db.createFile("repair.txt", "text/plain", "file", bytes))
    const store = makeAttachmentStore(directory)
    await store.put(bytes, metadata.sha256)
    await run(db.markFileStorageDual(metadata.id))
    writeFileSync(store.objectPath(metadata.sha256), "corrupt")

    await migrateAttachmentBlobs(db, store)

    expect((await run(db.getFileStorage(metadata.id)))?.storageState).toBe("disk")
    expect((await store.read(metadata)).equals(bytes)).toBe(true)
  })
})
