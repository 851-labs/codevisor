import type { Effect } from "effect"

import type { DatabaseSpaceService } from "./database-space.js"
import type { DatabaseError } from "./errors.js"
import type { FileStorageRecord, FileStorageState } from "./rows.js"
import type { StoredFileReferences } from "./session-files.js"
import type { UnusedFile } from "./unused-files.js"

export interface FileStorageService extends DatabaseSpaceService {
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
  readonly listUnusedFiles: Effect.Effect<ReadonlyArray<UnusedFile>, DatabaseError>
  readonly deleteFiles: (ids: ReadonlyArray<string>) => Effect.Effect<void, DatabaseError>
}
