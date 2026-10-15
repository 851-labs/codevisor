import { AttachmentKind, type FileMetadata } from "@codevisor/api"
import { Schema } from "effect"

import { blob, integer, literal, rowReader, text } from "./row-reader.js"

export interface FileMetadataRow {
  readonly id: string
  readonly name: string
  readonly mime_type: string
  readonly size_bytes: number
  readonly sha256: string
  readonly kind: AttachmentKind
  readonly created_at: string
}

export interface FileRow extends FileMetadataRow {
  readonly storage_state: FileStorageState
}

export interface FileStorageRow extends FileRow {
  readonly data: Buffer
}

export const fileStorageState = literal("sqlite", "dual", "disk")

export type FileStorageState = "sqlite" | "dual" | "disk"

export interface FileStorageRecord {
  readonly metadata: FileMetadata
  readonly storageState: FileStorageState
  readonly data: Buffer
}

export const fileMetadataRows = rowReader<FileMetadataRow>({
  id: text,
  name: text,
  mime_type: text,
  size_bytes: integer,
  sha256: text,
  kind: Schema.is(AttachmentKind),
  created_at: text
})

export const fileStorageRows = rowReader<FileStorageRow>({
  ...fileMetadataRows.columns,
  storage_state: fileStorageState,
  data: blob
})
