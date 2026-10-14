import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { readFile } from "node:fs/promises"
import { join } from "node:path"

export const isValidBlobId = (value: string): boolean => /^[a-f0-9]{64}$/.test(value)

export interface BlobStore {
  readonly has: (id: string) => boolean
  readonly path: (id: string) => string
  readonly read: (id: string) => Promise<Buffer>
  readonly write: (id: string, bytes: Uint8Array) => void
  readonly remove: (id: string) => void
}

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
