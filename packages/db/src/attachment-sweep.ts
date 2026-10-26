import { readdir, rm } from "node:fs/promises"
import { join } from "node:path"

import { Effect } from "effect"

import {
  attachmentCopiesRoot,
  attachmentObjectsRoot,
  isAttachmentSha256,
  safePathSegment,
  type AttachmentStore
} from "./attachment-store.js"
import type { CodevisorDatabaseService } from "./index.js"

export const removeUnreferencedAttachments = async (
  db: CodevisorDatabaseService,
  store: AttachmentStore
): Promise<void> => {
  const references = await Effect.runPromise(db.storedFileReferences)
  await removeUnreferencedObjects(attachmentObjectsRoot(store.root), references.sha256s)
  await removeUnreferencedCopies(attachmentCopiesRoot(store.root), references.fileIds)
}

const removeUnreferencedObjects = async (
  objectsRoot: string,
  sha256s: ReadonlySet<string>
): Promise<void> => {
  for (const prefix of await entriesOf(objectsRoot)) {
    const directory = join(objectsRoot, prefix)
    for (const name of await entriesOf(directory)) {
      if (isUnreferencedObject(name, sha256s)) await rm(join(directory, name), { force: true })
    }
  }
}

const removeUnreferencedCopies = async (
  copiesRoot: string,
  fileIds: ReadonlySet<string>
): Promise<void> => {
  const kept = new Set([...fileIds].map(safePathSegment))
  for (const name of await entriesOf(copiesRoot)) {
    if (!kept.has(name)) await rm(join(copiesRoot, name), { force: true, recursive: true })
  }
}

const isUnreferencedObject = (name: string, sha256s: ReadonlySet<string>): boolean =>
  isAttachmentSha256(name) && !sha256s.has(name)

const entriesOf = async (directory: string): Promise<ReadonlyArray<string>> =>
  readdir(directory).catch(() => [])
