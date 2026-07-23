import Database from "better-sqlite3"
import { Effect } from "effect"
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
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

  it("rejects invalid identities and corrupt objects", async () => {
    const directory = temporaryDirectory()
    const store = makeAttachmentStore(directory)
    const bytes = Buffer.from("expected attachment")
    const stored = await store.put(bytes)

    expect(() => store.objectPath("not-a-sha")).toThrow("Invalid attachment SHA-256")
    await expect(store.put(bytes, "0".repeat(64))).rejects.toThrow("Attachment checksum mismatch")
    await expect(
      store.read({
        id: "wrong-size",
        name: "wrong-size.txt",
        mimeType: "text/plain",
        sizeBytes: bytes.byteLength + 1,
        sha256: stored.sha256,
        kind: "file",
        createdAt: new Date().toISOString()
      })
    ).rejects.toThrow("Attachment object is missing or corrupt")

    writeFileSync(stored.path, Buffer.alloc(bytes.byteLength, 0))
    expect(await store.verify({ sha256: stored.sha256, sizeBytes: bytes.byteLength })).toBe(false)
    await expect(
      store.read({
        id: "wrong-hash",
        name: "wrong-hash.txt",
        mimeType: "text/plain",
        sizeBytes: bytes.byteLength,
        sha256: stored.sha256,
        kind: "file",
        createdAt: new Date().toISOString()
      })
    ).rejects.toThrow("Attachment object is missing or corrupt")
  })

  it("returns false when an object is missing, has the wrong size, or is not a file", async () => {
    const directory = temporaryDirectory()
    const store = makeAttachmentStore(directory)
    const missingSha = "1".repeat(64)
    expect(await store.verify({ sha256: missingSha, sizeBytes: 1 })).toBe(false)

    const wrongSize = await store.put(Buffer.from("size"))
    expect(await store.verify({ sha256: wrongSize.sha256, sizeBytes: 99 })).toBe(false)

    const directorySha = "2".repeat(64)
    const directoryPath = store.objectPath(directorySha)
    mkdirSync(dirname(directoryPath), { recursive: true })
    mkdirSync(directoryPath)
    expect(await store.verify({ sha256: directorySha, sizeBytes: 0 })).toBe(false)
  })

  it("streams typed-array chunks, bounds the header, and cleans up interrupted writes", async () => {
    const directory = temporaryDirectory()
    const store = makeAttachmentStore(directory)
    const first = Uint8Array.from({ length: 40 }, (_, index) => index)
    const stored = await store.putStream(
      (async function* () {
        yield first
        yield Uint8Array.from([40, 41])
      })()
    )

    expect(stored.header).toEqual(Buffer.from(first.subarray(0, 32)))
    expect(stored.sizeBytes).toBe(42)

    await expect(
      store.putStream(
        (async function* () {
          yield Uint8Array.from([1, 2, 3])
          throw new Error("stream interrupted")
        })()
      )
    ).rejects.toThrow("stream interrupted")
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

  it("reports an empty migration as complete", async () => {
    const directory = temporaryDirectory()
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "local" })
    )
    databases.push(db)
    const progress: Array<{ readonly completed: number; readonly total: number }> = []

    await migrateAttachmentBlobs(db, makeAttachmentStore(directory), (value) =>
      progress.push(value)
    )

    expect(progress.at(-1)).toMatchObject({ completed: 1, total: 1 })
  })

  it("rejects corrupt legacy bytes without clearing SQLite", async () => {
    const directory = temporaryDirectory()
    const filename = join(directory, "codevisor.sqlite")
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    databases.push(db)
    const metadata = await run(
      db.createFile("corrupt.txt", "text/plain", "file", Buffer.from("ok"))
    )
    const sqlite = new Database(filename)
    sqlite.prepare("update files set data = ? where id = ?").run(Buffer.from("no"), metadata.id)
    sqlite.close()
    const failures: Array<string | undefined> = []

    await expect(
      migrateAttachmentBlobs(db, makeAttachmentStore(directory), (value) => {
        if (value.state === "failed") failures.push(value.error)
      })
    ).rejects.toThrow("Legacy attachment failed verification")
    expect(failures).toEqual([expect.stringContaining("Legacy attachment failed verification")])
    expect((await run(db.getFileStorage(metadata.id)))?.storageState).toBe("sqlite")
  })

  it("rejects corrupt retained bytes during dual-storage repair", async () => {
    const directory = temporaryDirectory()
    const filename = join(directory, "codevisor.sqlite")
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    databases.push(db)
    const metadata = await run(
      db.createFile("dual.txt", "text/plain", "file", Buffer.from("valid"))
    )
    await run(db.markFileStorageDual(metadata.id))
    const sqlite = new Database(filename)
    sqlite.prepare("update files set data = ? where id = ?").run(Buffer.from("bad"), metadata.id)
    sqlite.close()

    await expect(migrateAttachmentBlobs(db, makeAttachmentStore(directory))).rejects.toThrow(
      "Attachment failed verification before clearing its SQLite BLOB"
    )
    expect((await run(db.getFileStorage(metadata.id)))?.storageState).toBe("dual")
  })

  it("keeps dual storage when a repaired object still cannot be verified", async () => {
    const directory = temporaryDirectory()
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "local" })
    )
    databases.push(db)
    const metadata = await run(
      db.createFile("unverified.txt", "text/plain", "file", Buffer.from("valid"))
    )
    await run(db.markFileStorageDual(metadata.id))
    const store = makeAttachmentStore(directory)
    const neverVerifies: AttachmentStore = {
      ...store,
      verify: async () => false
    }

    await expect(migrateAttachmentBlobs(db, neverVerifies)).rejects.toThrow(
      "Attachment repair failed before clearing its SQLite BLOB"
    )
    expect((await run(db.getFileStorage(metadata.id)))?.storageState).toBe("dual")
  })

  it("reports non-Error migration failures", async () => {
    const directory = temporaryDirectory()
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "local" })
    )
    databases.push(db)
    await run(db.createFile("failure.txt", "text/plain", "file", Buffer.from("failure")))
    const store = makeAttachmentStore(directory)
    const failing: AttachmentStore = {
      ...store,
      put: async () => await Promise.reject("non-error failure")
    }
    const failures: Array<string | undefined> = []

    await expect(
      migrateAttachmentBlobs(db, failing, (value) => {
        if (value.state === "failed") failures.push(value.error)
      })
    ).rejects.toBe("non-error failure")
    expect(failures).toEqual(["non-error failure"])
  })

  it("covers disk-file creation and idempotent storage transitions", async () => {
    const directory = temporaryDirectory()
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "local" })
    )
    databases.push(db)
    const original = await run(
      db.createFile("state.txt", "text/plain", "file", Buffer.from("state"))
    )
    const diskMetadata = { ...original, id: "disk-file", name: "disk.txt" }

    expect(await run(db.createDiskFile(diskMetadata))).toEqual(diskMetadata)
    expect(await run(db.getFileStorage("missing"))).toBeUndefined()
    expect(await run(db.getFileStorage(diskMetadata.id))).toMatchObject({
      data: Buffer.alloc(0),
      storageState: "disk"
    })

    await run(db.markFileStorageDual(original.id))
    await run(db.markFileStorageDual(original.id))
    await run(db.markFileStorageDisk(original.id))
    await run(db.markFileStorageDual(original.id))
    await run(db.markFileStorageDisk(original.id))
    await expect(run(db.markFileStorageDual("missing"))).rejects.toThrow(
      "File not found while marking dual storage"
    )
    await expect(run(db.markFileStorageDisk("missing"))).rejects.toThrow(
      "File is not ready for disk-only storage"
    )

    const sqliteOnly = await run(
      db.createFile("sqlite.txt", "text/plain", "file", Buffer.from("sqlite"))
    )
    await expect(run(db.markFileStorageDisk(sqliteOnly.id))).rejects.toThrow(
      "File is not ready for disk-only storage"
    )
  })
})
