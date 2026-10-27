import type { Effect } from "effect"

import type { DatabaseError } from "./errors.js"
import type { FileStorageRecord, FileStorageState } from "./rows.js"
import type { StoredFileReferences } from "./session-files.js"

export interface FileStorageService {
  readonly getFileStorage: (
    id: string
  ) => Effect.Effect<FileStorageRecord | undefined, DatabaseError>
  readonly listFileStorage: (
    state: FileStorageState,
    limit: number
  ) => Effect.Effect<ReadonlyArray<FileStorageRecord>, DatabaseError>
  readonly fileStorageCounts: Effect.Effect<
    Readonly<Record<FileStorageState, number>>,
    DatabaseError
  >
  readonly markFileStorageDual: (id: string) => Effect.Effect<void, DatabaseError>
  readonly markFileStorageDisk: (id: string) => Effect.Effect<void, DatabaseError>
  readonly storedFileReferences: Effect.Effect<StoredFileReferences, DatabaseError>
}
