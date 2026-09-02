import type { PromptAttachmentInput } from "@codevisor/agent-runtime"
import { createHash } from "node:crypto"
import type { AttachmentRef, FileMetadata } from "@codevisor/api"
import { AttachmentStoreError } from "@codevisor/db"
import { existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { CodevisorServerServices } from "./server-context-types.js"
import { run, HttpFailure } from "./server-http.js"

/// Prompt attachment handling: temp-file staging, disk-backed reads, byte
/// ranges, and the periodic sweep.

const ATTACHMENT_TEMP_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

const attachmentsTempRoot = (): string => join(tmpdir(), "codevisor-attachments")

export const sanitizeFileName = (name: string): string => {
  // oxlint-disable-next-line no-control-regex
  const cleaned = name.replace(/[/\\:\0]/g, "_").replace(/^\.+/, "")
  return cleaned.length === 0 ? "attachment" : cleaned
}

const readAttachment = async (
  services: CodevisorServerServices,
  fileId: string
): Promise<{ readonly data: Buffer; readonly metadata: FileMetadata }> => {
  const record = await run(services.db.getFileStorage(fileId))
  if (record === undefined) {
    throw new HttpFailure(404, `File not found: ${fileId}`)
  }
  const store = services.attachments
  if (record.storageState !== "sqlite") {
    try {
      return { data: await store.read(record.metadata), metadata: record.metadata }
    } catch (cause) {
      if (record.storageState === "disk") throw cause
      // Dual rows retain their legacy bytes until the disk object has been
      // reverified, so a damaged copy remains recoverable during migration.
    }
  }
  if (
    record.data.byteLength !== record.metadata.sizeBytes ||
    createHash("sha256").update(record.data).digest("hex") !== record.metadata.sha256
  ) {
    throw new AttachmentStoreError(`Attachment bytes are missing or corrupt: ${fileId}`)
  }
  await store.put(record.data, record.metadata.sha256)
  await run(services.db.markFileStorageDual(fileId))
  return { data: record.data, metadata: record.metadata }
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
    } catch {
      // A dual row can be reconstructed from its legacy bytes below.
    }
    if (record.storageState === "disk") {
      throw new AttachmentStoreError(`Attachment object is missing: ${fileId}`)
    }
  }
  await readAttachment(services, fileId)
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
  /* v8 ignore next -- both capture groups are guaranteed by the matched expression. */
  const startText = match[1] ?? ""
  /* v8 ignore next -- both capture groups are guaranteed by the matched expression. */
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

/// Materializes attachment bytes as temp files so path-based provider inputs
/// (Codex localImage, path notes for arbitrary files) can reference them.
/// Files are immutable, so an existing materialization is reused.
export const resolvePromptAttachments = async (
  services: CodevisorServerServices,
  refs: ReadonlyArray<AttachmentRef>
): Promise<Array<PromptAttachmentInput>> => {
  const resolved: Array<PromptAttachmentInput> = []
  for (const ref of refs) {
    let file: Awaited<ReturnType<typeof readAttachment>>
    try {
      file = await readAttachment(services, ref.fileId)
    } catch (cause) {
      if (cause instanceof HttpFailure && cause.status === 404) {
        throw new HttpFailure(422, `Attachment file missing: ${ref.fileId}`)
      }
      throw cause
    }
    const directory = join(attachmentsTempRoot(), ref.fileId)
    mkdirSync(directory, { recursive: true })
    const path = join(directory, sanitizeFileName(ref.name))
    if (!existsSync(path)) {
      writeFileSync(path, file.data)
    }
    resolved.push({ data: file.data, kind: ref.kind, mimeType: ref.mimeType, name: ref.name, path })
  }
  return resolved
}

/// Best-effort start-up sweep of stale materialized attachments; OS tmp
/// reaping is the backstop.
export const sweepAttachmentTempFiles = (now = Date.now()): void => {
  try {
    for (const entry of readdirSync(attachmentsTempRoot())) {
      const path = join(attachmentsTempRoot(), entry)
      try {
        if (now - statSync(path).mtimeMs > ATTACHMENT_TEMP_MAX_AGE_MS) {
          rmSync(path, { force: true, recursive: true })
        }
      } catch {
        // Another process may have removed the entry mid-sweep.
      }
    }
  } catch {
    // The temp root does not exist until the first attachment is resolved.
  }
}

/// Archiving retires the session's runtime: the agent process shuts down and
/// every background-task terminal it registered is killed and removed — a
/// dev server must not keep running under an archived chat. Best-effort: the
/// archive itself must succeed even if the runtime is already gone.
