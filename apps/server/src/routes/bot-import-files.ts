import { createReadStream } from "node:fs"
import { appendFile, mkdir, rm, stat, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { FileMetadata } from "@codevisor/api"

import { HttpFailure, run, type CodevisorServerServices } from "../server-context.js"

export interface ImportFileChunk {
  readonly file: FileMetadata
  readonly offset: number
  readonly data: string
}

export const missingImportFiles = async (
  services: CodevisorServerServices,
  fileIds: ReadonlyArray<string>
): Promise<ReadonlyArray<string>> => {
  const missing: Array<string> = []
  for (const fileId of fileIds) {
    if ((await run(services.db.getFileMetadata(fileId))) === undefined) missing.push(fileId)
  }
  return missing
}

export const receiveImportFile = async (
  services: CodevisorServerServices,
  chunk: ImportFileChunk
): Promise<{ readonly stored: boolean }> => {
  const part = await writeChunk(chunk)
  if ((await stat(part)).size < chunk.file.sizeBytes) return { stored: false }

  try {
    await storeFile(services, chunk.file, part)
  } finally {
    await rm(part, { force: true })
  }
  return { stored: true }
}

const writeChunk = async (chunk: ImportFileChunk): Promise<string> => {
  const part = partPath(chunk.file)
  await mkdir(importDirectory, { recursive: true })
  const bytes = Buffer.from(chunk.data, "base64")
  if (chunk.offset === 0) await writeFile(part, bytes)
  else await appendFile(part, bytes)
  return part
}

const storeFile = async (
  services: CodevisorServerServices,
  file: FileMetadata,
  part: string
): Promise<void> => {
  const stored = await services.attachments.putStream(createReadStream(part))
  if (stored.sha256 !== file.sha256) {
    throw new HttpFailure(422, `${file.name} arrived damaged; fork again to resend it`)
  }
  if ((await run(services.db.getFileMetadata(file.id))) !== undefined) return

  await run(services.db.createDiskFile(file))
}

const importDirectory = join(tmpdir(), "codevisor-bot-imports")

const partPath = (file: FileMetadata): string => join(importDirectory, `${file.id}.part`)
