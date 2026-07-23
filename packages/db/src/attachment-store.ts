import type { DataUpgradeProgress, FileMetadata } from "@codevisor/api"
import { Effect } from "effect"
import { createHash, randomUUID } from "node:crypto"
import { createReadStream } from "node:fs"
import { chmod, mkdir, open, readFile, rename, rm, stat } from "node:fs/promises"
import { dirname, join } from "node:path"
import type { CodevisorDatabaseService } from "./index.js"

const sha256Pattern = /^[0-9a-f]{64}$/
const migrationId = "attachment-object-store-v1"
const migrationName = "Moving attachments to disk"

export class AttachmentStoreError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "AttachmentStoreError"
  }
}

export interface StoredAttachmentObject {
  readonly header: Buffer
  readonly path: string
  readonly sha256: string
  readonly sizeBytes: number
}

export interface AttachmentStore {
  readonly root: string
  readonly objectPath: (sha256: string) => string
  readonly put: (data: Buffer, expectedSha256?: string) => Promise<StoredAttachmentObject>
  readonly putStream: (source: AsyncIterable<Uint8Array>) => Promise<StoredAttachmentObject>
  readonly read: (metadata: FileMetadata) => Promise<Buffer>
  readonly verify: (metadata: Pick<FileMetadata, "sha256" | "sizeBytes">) => Promise<boolean>
}

const hashFile = async (path: string): Promise<string> =>
  await new Promise((resolve, reject) => {
    const hash = createHash("sha256")
    const stream = createReadStream(path)
    stream.on("data", (chunk: Buffer) => hash.update(chunk))
    stream.once("error", reject)
    stream.once("end", () => resolve(hash.digest("hex")))
  })

const writeAll = async (
  handle: Awaited<ReturnType<typeof open>>,
  buffer: Buffer,
  position: number
): Promise<number> => {
  let offset = 0
  while (offset < buffer.byteLength) {
    const result = await handle.write(buffer, offset, buffer.byteLength - offset, position + offset)
    /* v8 ignore next 3 -- a real FileHandle either writes bytes or rejects; this guards a broken adapter. */
    if (result.bytesWritten === 0) {
      throw new AttachmentStoreError("Unable to make progress writing attachment")
    }
    offset += result.bytesWritten
  }
  return offset
}

const syncDirectory = async (path: string): Promise<void> => {
  // Windows does not support opening directories for fsync. The file itself
  // is still synced before the atomic rename.
  /* v8 ignore next -- CI exercises fsync on Unix; Windows rejects directory handles by design. */
  if (process.platform === "win32") return
  const handle = await open(path, "r")
  try {
    await handle.sync()
  } finally {
    await handle.close()
  }
}

export const makeAttachmentStore = (dataDir: string): AttachmentStore => {
  const root = join(dataDir, "attachments")
  const objectsRoot = join(root, "objects", "sha256")
  const stagingRoot = join(root, "staging")

  const objectPath = (sha256: string): string => {
    if (!sha256Pattern.test(sha256)) {
      throw new AttachmentStoreError(`Invalid attachment SHA-256: ${sha256}`)
    }
    return join(objectsRoot, sha256.slice(0, 2), sha256)
  }

  const verify = async (metadata: Pick<FileMetadata, "sha256" | "sizeBytes">): Promise<boolean> => {
    const path = objectPath(metadata.sha256)
    try {
      const info = await stat(path)
      return (
        info.isFile() &&
        info.size === metadata.sizeBytes &&
        (await hashFile(path)) === metadata.sha256
      )
    } catch {
      return false
    }
  }

  const installStaged = async (
    temporary: string,
    sha256: string,
    sizeBytes: number,
    header: Buffer
  ): Promise<StoredAttachmentObject> => {
    const path = objectPath(sha256)
    await mkdir(join(objectsRoot, sha256.slice(0, 2)), { mode: 0o700, recursive: true })
    if (await verify({ sha256, sizeBytes })) {
      await rm(temporary, { force: true })
      return { header, path, sha256, sizeBytes }
    }
    try {
      await rename(temporary, path)
      /* v8 ignore start -- requires another process to install the same object during this rename. */
    } catch (cause) {
      if (!(await verify({ sha256, sizeBytes }))) throw cause
      await rm(temporary, { force: true })
    }
    /* v8 ignore stop */
    await chmod(path, 0o600)
    await syncDirectory(dirname(path))
    /* v8 ignore next 3 -- requires external corruption between the atomic rename and immediate verification. */
    if (!(await verify({ sha256, sizeBytes }))) {
      throw new AttachmentStoreError(`Attachment object failed verification: ${sha256}`)
    }
    return { header, path, sha256, sizeBytes }
  }

  const putStream = async (source: AsyncIterable<Uint8Array>): Promise<StoredAttachmentObject> => {
    await mkdir(stagingRoot, { mode: 0o700, recursive: true })
    const temporary = join(stagingRoot, `${process.pid}-${randomUUID()}.tmp`)
    const handle = await open(temporary, "wx", 0o600)
    const hash = createHash("sha256")
    const headerChunks: Array<Buffer> = []
    let headerBytes = 0
    let position = 0
    try {
      for await (const value of source) {
        const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value)
        position += chunk.byteLength
        hash.update(chunk)
        if (headerBytes < 32) {
          const prefix = chunk.subarray(0, Math.min(chunk.byteLength, 32 - headerBytes))
          headerChunks.push(prefix)
          headerBytes += prefix.byteLength
        }
        await writeAll(handle, chunk, position - chunk.byteLength)
      }
      await handle.sync()
      await handle.close()
      const sha256 = hash.digest("hex")
      return await installStaged(
        temporary,
        sha256,
        position,
        Buffer.concat(headerChunks, headerBytes)
      )
    } catch (cause) {
      await handle.close().catch(
        /* v8 ignore next -- best-effort cleanup after the primary write failure. */
        () => undefined
      )
      await rm(temporary, { force: true }).catch(
        /* v8 ignore next -- best-effort cleanup after the primary write failure. */
        () => undefined
      )
      throw cause
    }
  }

  const put = async (data: Buffer, expectedSha256?: string): Promise<StoredAttachmentObject> => {
    const actual = createHash("sha256").update(data).digest("hex")
    if (expectedSha256 !== undefined && actual !== expectedSha256) {
      throw new AttachmentStoreError(
        `Attachment checksum mismatch: expected ${expectedSha256}, received ${actual}`
      )
    }
    return await putStream(
      (async function* () {
        yield data
      })()
    )
  }

  const read = async (metadata: FileMetadata): Promise<Buffer> => {
    const path = objectPath(metadata.sha256)
    const data = await readFile(path)
    if (
      data.byteLength !== metadata.sizeBytes ||
      createHash("sha256").update(data).digest("hex") !== metadata.sha256
    ) {
      throw new AttachmentStoreError(`Attachment object is missing or corrupt: ${metadata.id}`)
    }
    return data
  }

  return { objectPath, put, putStream, read, root, verify }
}

export const migrateAttachmentBlobs = async (
  db: CodevisorDatabaseService,
  store: AttachmentStore,
  onProgress?: (progress: DataUpgradeProgress) => void
): Promise<void> => {
  const initial = await Effect.runPromise(db.fileStorageCounts)
  const total = initial.sqlite + initial.dual + initial.disk
  const report = (state: DataUpgradeProgress["state"], completed: number, error?: string): void => {
    onProgress?.({
      state,
      id: migrationId,
      name: migrationName,
      completed: total === 0 ? 1 : completed,
      total: Math.max(1, total),
      ...(error === undefined ? {} : { error })
    })
  }

  try {
    report("running", initial.disk)
    while (true) {
      // A row may be the full upload limit, so process one BLOB at a time to
      // keep startup backfill memory bounded.
      const rows = await Effect.runPromise(db.listFileStorage("sqlite", 1))
      if (rows.length === 0) break
      for (const row of rows) {
        if (
          row.data.byteLength !== row.metadata.sizeBytes ||
          createHash("sha256").update(row.data).digest("hex") !== row.metadata.sha256
        ) {
          throw new AttachmentStoreError(
            `Legacy attachment failed verification before migration: ${row.metadata.id}`
          )
        }
        await store.put(row.data, row.metadata.sha256)
        await Effect.runPromise(db.markFileStorageDual(row.metadata.id))
      }
      const counts = await Effect.runPromise(db.fileStorageCounts)
      report("running", counts.disk)
    }

    while (true) {
      const rows = await Effect.runPromise(db.listFileStorage("dual", 1))
      if (rows.length === 0) break
      for (const row of rows) {
        if (!(await store.verify(row.metadata))) {
          if (
            row.data.byteLength !== row.metadata.sizeBytes ||
            createHash("sha256").update(row.data).digest("hex") !== row.metadata.sha256
          ) {
            throw new AttachmentStoreError(
              `Attachment failed verification before clearing its SQLite BLOB: ${row.metadata.id}`
            )
          }
          await store.put(row.data, row.metadata.sha256)
          if (!(await store.verify(row.metadata))) {
            throw new AttachmentStoreError(
              `Attachment repair failed before clearing its SQLite BLOB: ${row.metadata.id}`
            )
          }
        }
        await Effect.runPromise(db.markFileStorageDisk(row.metadata.id))
      }
      const counts = await Effect.runPromise(db.fileStorageCounts)
      report("running", counts.disk)
    }
    report("completed", total)
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    const counts = await Effect.runPromise(db.fileStorageCounts)
    report("failed", counts.disk, message)
    throw cause
  }
}
