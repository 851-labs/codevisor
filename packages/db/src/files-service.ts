import type { FileMetadata } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { createHash, randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { fileMetadataFromRow, fileStorageRecordFromRow } from "./row-mappers.js"
import type { FileRow, FileStorageState } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

export const makeFilesService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "createFile"
  | "createDiskFile"
  | "getFileMetadata"
  | "getFile"
  | "getFileStorage"
  | "listFileStorage"
  | "fileStorageCounts"
  | "markFileStorageDual"
  | "markFileStorageDisk"
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
          .prepare(
            `insert into files (
              id, name, mime_type, size_bytes, sha256, kind, created_at, data
            ) values (?, ?, ?, ?, ?, ?, ?, ?)`
          )
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
          .prepare(
            `insert into files (
              id, name, mime_type, size_bytes, sha256, kind, created_at, data, storage_state
            ) values (?, ?, ?, ?, ?, ?, ?, ?, 'disk')`
          )
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
        const row = sqlite
          .prepare(
            "select id, name, mime_type, size_bytes, sha256, kind, created_at from files where id = ?"
          )
          .get(id) as FileRow | undefined
        return row === undefined ? undefined : fileMetadataFromRow(row)
      }),
    getFile: (id) =>
      attempt("getFile", () => {
        const row = sqlite.prepare("select * from files where id = ?").get(id) as
          | (FileRow & { readonly data: Buffer })
          | undefined
        return row === undefined
          ? undefined
          : { metadata: fileMetadataFromRow(row), data: row.data }
      }),
    getFileStorage: (id) =>
      attempt("getFileStorage", () => {
        const row = sqlite.prepare("select * from files where id = ?").get(id) as
          | (FileRow & { readonly data: Buffer })
          | undefined
        return row === undefined ? undefined : fileStorageRecordFromRow(row)
      }),
    listFileStorage: (state, limit) =>
      attempt("listFileStorage", () =>
        (
          sqlite
            .prepare("select * from files where storage_state = ? order by rowid asc limit ?")
            .all(state, Math.max(1, limit)) as ReadonlyArray<FileRow & { readonly data: Buffer }>
        ).map(fileStorageRecordFromRow)
      ),
    fileStorageCounts: attempt("fileStorageCounts", () => {
      const counts: Record<FileStorageState, number> = { disk: 0, dual: 0, sqlite: 0 }
      const rows = sqlite
        .prepare("select storage_state, count(*) as count from files group by storage_state")
        .all() as ReadonlyArray<{
        readonly storage_state: FileStorageState
        readonly count: number
      }>
      for (const row of rows) counts[row.storage_state] = Number(row.count)
      return counts
    }),
    markFileStorageDual: (id) =>
      attempt("markFileStorageDual", () => {
        const result = sqlite
          .prepare(
            "update files set storage_state = 'dual' where id = ? and storage_state = 'sqlite'"
          )
          .run(id)
        if (result.changes === 0) {
          const current = sqlite.prepare("select storage_state from files where id = ?").get(id) as
            | { readonly storage_state: FileStorageState }
            | undefined
          if (current?.storage_state !== "dual" && current?.storage_state !== "disk") {
            throw new Error(`File not found while marking dual storage: ${id}`)
          }
        }
      }),
    markFileStorageDisk: (id) =>
      attempt("markFileStorageDisk", () => {
        const result = sqlite
          .prepare(
            "update files set storage_state = 'disk', data = x'' where id = ? and storage_state = 'dual'"
          )
          .run(id)
        if (result.changes === 0) {
          const current = sqlite.prepare("select storage_state from files where id = ?").get(id) as
            | { readonly storage_state: FileStorageState }
            | undefined
          if (current?.storage_state !== "disk") {
            throw new Error(`File is not ready for disk-only storage: ${id}`)
          }
        }
      })
  }
}
