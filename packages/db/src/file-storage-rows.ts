import type { AttachmentKind, FileMetadata } from "@codevisor/api"

export interface FileRow {
  readonly id: string
  readonly name: string
  readonly mime_type: string
  readonly size_bytes: number
  readonly sha256: string
  readonly kind: AttachmentKind
  readonly created_at: string
  readonly storage_state: FileStorageState
}

export type FileStorageState = "sqlite" | "dual" | "disk"

export interface FileStorageRecord {
  readonly metadata: FileMetadata
  readonly storageState: FileStorageState
  readonly data: Buffer
}
