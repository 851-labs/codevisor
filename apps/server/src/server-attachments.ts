import { createHash, randomUUID } from "node:crypto"
import { constants, existsSync, mkdirSync, readdirSync, rmSync, statSync } from "node:fs"
import { copyFile, rename } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { PromptAttachmentInput } from "@codevisor/agent-runtime"
import type { AttachmentRef, FileMetadata } from "@codevisor/api"
import { AttachmentStoreError } from "@codevisor/db"

import { inlineSizing } from "./infra/prompt-media.js"
import type { CodevisorServerServices } from "./server-context-types.js"
import { run, HttpFailure } from "./server-http.js"

const ATTACHMENT_TEMP_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

const attachmentsTempRoot = (): string => join(tmpdir(), "codevisor-attachments")

export const sanitizeFileName = (name: string): string => {
  const cleaned = name.replace(/[/\\:\0]/g, "_").replace(/^\.+/, "")
  return cleaned.length === 0 ? "attachment" : cleaned
}

const restoreLegacyObject = async (
  services: CodevisorServerServices,
  fileId: string,
  record: { readonly data: Buffer; readonly metadata: FileMetadata }
): Promise<void> => {
  if (
    record.data.byteLength !== record.metadata.sizeBytes ||
    createHash("sha256").update(record.data).digest("hex") !== record.metadata.sha256
  ) {
    throw new AttachmentStoreError(`Attachment bytes are missing or corrupt: ${fileId}`)
  }
  await services.attachments.put(record.data, record.metadata.sha256)
  await run(services.db.markFileStorageDual(fileId))
}

export const attachmentDiskFile = async (
  services: CodevisorServerServices,
  fileId: string
): Promise<{ readonly path: string; readonly metadata: FileMetadata }> => {
  const record = await run(services.db.getFileStorage(fileId))
  if (record === undefined) throw new HttpFailure(404, `File not found: ${fileId}`)
  const path = services.attachments.objectPath(record.metadata.sha256)
  if (record.storageState !== "sqlite") {
    try {
      const info = statSync(path)
      if (
        info.isFile() &&
        info.size === record.metadata.sizeBytes &&
        (record.storageState === "disk" || (await services.attachments.verify(record.metadata)))
      ) {
        return { path, metadata: record.metadata }
      }
    } catch {}
    if (record.storageState === "disk") {
      throw new AttachmentStoreError(`Attachment object is missing: ${fileId}`)
    }
  }
  await restoreLegacyObject(services, fileId, record)
  return { path, metadata: record.metadata }
}

export type ByteRange = { readonly start: number; readonly end: number }

export const requestedByteRange = (
  header: string | undefined,
  size: number
): ByteRange | "invalid" | undefined => {
  if (header === undefined) return undefined
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim())
  if (match === null || size <= 0) return "invalid"
  /* v8 ignore next */
  const startText = match[1] ?? ""
  /* v8 ignore next */
  const endText = match[2] ?? ""
  if (startText.length === 0) {
    const suffix = Number(endText)
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return "invalid"
    return { start: Math.max(0, size - suffix), end: size - 1 }
  }
  const start = Number(startText)
  const requestedEnd = endText.length === 0 ? size - 1 : Number(endText)
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(requestedEnd) ||
    start < 0 ||
    start >= size ||
    requestedEnd < start
  ) {
    return "invalid"
  }
  return { start, end: Math.min(requestedEnd, size - 1) }
}

export const resolvePromptAttachments = async (
  services: CodevisorServerServices,
  refs: ReadonlyArray<AttachmentRef>
): Promise<Array<PromptAttachmentInput>> => {
  const resolved: Array<PromptAttachmentInput> = []
  for (const ref of refs) {
    let file: Awaited<ReturnType<typeof attachmentDiskFile>>
    try {
      file = await attachmentDiskFile(services, ref.fileId)
    } catch (cause) {
      if (cause instanceof HttpFailure && cause.status === 404) {
        throw new HttpFailure(422, `Attachment file missing: ${ref.fileId}`)
      }
      throw cause
    }
    if (!(await services.attachments.verify(file.metadata))) {
      throw new AttachmentStoreError(`Attachment object is missing or corrupt: ${ref.fileId}`)
    }
    const directory = join(attachmentsTempRoot(), ref.fileId)
    mkdirSync(directory, { recursive: true })
    const path = join(directory, sanitizeFileName(ref.name))
    if (!existsSync(path)) {
      const partial = `${path}.${randomUUID()}.partial`
      await copyFile(file.path, partial, constants.COPYFILE_FICLONE)
      await rename(partial, path)
    }
    const attachment = {
      kind: ref.kind,
      mimeType: ref.mimeType,
      name: ref.name,
      path,
      sizeBytes: file.metadata.sizeBytes
    }
    resolved.push({ ...attachment, ...(await inlineSizing(attachment)) })
  }
  return resolved
}

export const sweepAttachmentTempFiles = (now = Date.now()): void => {
  try {
    for (const entry of readdirSync(attachmentsTempRoot())) {
      const path = join(attachmentsTempRoot(), entry)
      try {
        if (now - statSync(path).mtimeMs > ATTACHMENT_TEMP_MAX_AGE_MS) {
          rmSync(path, { force: true, recursive: true })
        }
      } catch {}
    }
  } catch {}
}
