import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { readFile } from "node:fs/promises"
import { join } from "node:path"

/// True for the ids this store accepts: 64 lowercase hex characters (a
/// sha256 — for skill archives, the TREE hash of the unpacked contents,
/// so the id survives re-encoding of the archive bytes).
export const isValidBlobId = (value: string): boolean => /^[a-f0-9]{64}$/.test(value)

export interface BlobStore {
  readonly has: (id: string) => boolean
  readonly path: (id: string) => string
  readonly read: (id: string) => Promise<Buffer>
  /// Stores bytes under `id`. The caller owns semantic verification (for
  /// tree-hashed archives: unpack and compare) — this store only guards the
  /// id shape so ids can never traverse paths.
  readonly write: (id: string, bytes: Uint8Array) => void
  readonly remove: (id: string) => void
}

/// A dumb content-addressed byte store on disk: one file per id, written
/// atomically. Deliberately no eviction — blobs are small and referenced by
/// replicated documents whose tombstones drive explicit removal.
export const makeBlobStore = (directory: string): BlobStore => {
  const pathFor = (id: string): string => {
    if (!isValidBlobId(id)) throw new Error(`Invalid blob id: ${id}`)
    return join(directory, id)
  }
  return {
    has: (id) => existsSync(pathFor(id)),
    path: pathFor,
    read: (id) => readFile(pathFor(id)),
    write: (id, bytes) => {
      const destination = pathFor(id)
      mkdirSync(directory, { recursive: true })
      const temporary = `${destination}.${process.pid}.tmp`
      writeFileSync(temporary, bytes)
      renameSync(temporary, destination)
    },
    remove: (id) => {
      rmSync(pathFor(id), { force: true })
    }
  }
}
