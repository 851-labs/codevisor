import { createHash, randomUUID } from "node:crypto"

import type { FileMetadata } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import { attempt } from "./errors.js"
import { fileMetadataFromRow, fileStorageRecordFromRow } from "./row-mappers.js"
import { integer, rowReader } from "./row-reader.js"
import {
  fileMetadataRows,
  fileStorageRows,
  fileStorageState,
  type FileStorageState
} from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { storedFileReferences } from "./session-files.js"

const storageStateRows = rowReader({ storage_state: fileStorageState })

const storageCountRows = rowReader({ storage_state: fileStorageState, count: integer })

export const makeFilesService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "createFile"
  | "createDiskFile"
  | "getFileMetadata"
  | "getFileStorage"
  | "listFileStorage"
  | "fileStorageCounts"
  | "markFileStorageDual"
  | "markFileStorageDisk"
  | "storedFileReferences"
> => {
  const { sqlite } = context

  return {
    createFile: (name, mimeType, kind, data) =>
      attempt("createFile", () => {
        const metadata: FileMetadata = {
          id: randomUUID(),
          name,
          mimeType,
          sizeBytes: data.byteLength,
          sha256: createHash("sha256").update(data).digest("hex"),
          kind,
          createdAt: isoTimestamp()
        }
        sqlite
          .prepare(fileSql.insert)
          .run(
            metadata.id,
            metadata.name,
            metadata.mimeType,
            metadata.sizeBytes,
            metadata.sha256,
            metadata.kind,
            metadata.createdAt,
            data
          )
        return metadata
      }),
    createDiskFile: (metadata) =>
      attempt("createDiskFile", () => {
        sqlite
          .prepare(fileSql.insertDisk)
          .run(
            metadata.id,
            metadata.name,
            metadata.mimeType,
            metadata.sizeBytes,
            metadata.sha256,
            metadata.kind,
            metadata.createdAt,
            Buffer.alloc(0)
          )
        return metadata
      }),
    getFileMetadata: (id) =>
      attempt("getFileMetadata", () => {
        const row = fileMetadataRow(sqlite, id)
        return row === undefined ? undefined : fileMetadataFromRow(row)
      }),
    getFileStorage: (id) =>
      attempt("getFileStorage", () => {
        const row = fileStorageRow(sqlite, id)
        return row === undefined ? undefined : fileStorageRecordFromRow(row)
      }),
    listFileStorage: (state, limit) =>
      attempt("listFileStorage", () =>
        filesInState(sqlite, state, limit).map(fileStorageRecordFromRow)
      ),
    fileStorageCounts: attempt("fileStorageCounts", () => {
      const counts: Record<FileStorageState, number> = { disk: 0, dual: 0, sqlite: 0 }
      const rows = storageCounts(sqlite)
      for (const row of rows) counts[row.storage_state] = row.count
      return counts
    }),
    markFileStorageDual: (id) =>
      attempt("markFileStorageDual", () => {
        const result = sqlite.prepare(fileSql.markDual).run(id)
        if (result.changes === 0) {
          const current = storedState(sqlite, id)
          if (current !== "dual" && current !== "disk") {
            throw new Error(`File not found while marking dual storage: ${id}`)
          }
        }
      }),
    storedFileReferences: attempt("storedFileReferences", () => storedFileReferences(sqlite)),
    markFileStorageDisk: (id) =>
      attempt("markFileStorageDisk", () => {
        const result = sqlite.prepare(fileSql.markDisk).run(id)
        if (result.changes === 0) {
          if (storedState(sqlite, id) !== "disk") {
            throw new Error(`File is not ready for disk-only storage: ${id}`)
          }
        }
      })
  }
}

const fileMetadataRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  fileMetadataRows.maybe(sqlite.prepare(fileSql.metadata).get(id))

const fileStorageRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  fileStorageRows.maybe(sqlite.prepare(fileSql.byId).get(id))

const filesInState = (sqlite: ServiceContext["sqlite"], state: FileStorageState, limit: number) =>
  fileStorageRows.all(sqlite.prepare(fileSql.inState).all(state, Math.max(1, limit)))

const storageCounts = (sqlite: ServiceContext["sqlite"]) =>
  storageCountRows.all(sqlite.prepare(fileSql.stateCounts).all())

const storedState = (sqlite: ServiceContext["sqlite"], id: string): FileStorageState | undefined =>
  storageStateRows.maybe(sqlite.prepare(fileSql.storageState).get(id))?.storage_state

const fileSql = {
  insert: `insert into files (
              id, name, mime_type, size_bytes, sha256, kind, created_at, data
            ) values (?, ?, ?, ?, ?, ?, ?, ?)`,
  insertDisk: `insert into files (
              id, name, mime_type, size_bytes, sha256, kind, created_at, data, storage_state
            ) values (?, ?, ?, ?, ?, ?, ?, ?, 'disk')`,
  metadata:
    "select id, name, mime_type, size_bytes, sha256, kind, created_at from files where id = ?",
  byId: "select * from files where id = ?",
  inState: "select * from files where storage_state = ? order by rowid asc limit ?",
  stateCounts: "select storage_state, count(*) as count from files group by storage_state",
  markDual: "update files set storage_state = 'dual' where id = ? and storage_state = 'sqlite'",
  markDisk:
    "update files set storage_state = 'disk', data = x'' where id = ? and storage_state = 'dual'",
  storageState: "select storage_state from files where id = ?"
}
