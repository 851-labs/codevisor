import type { AttachmentRef, FileMetadata } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { createReadStream } from "node:fs"
import { stat } from "node:fs/promises"
import { basename } from "node:path"
import { run, type CodevisorServerServices } from "../server-context.js"
import { filesystemMimeType } from "./fs.js"

export const attachmentRef = (file: FileMetadata): AttachmentRef => ({
  fileId: file.id,
  name: file.name,
  mimeType: file.mimeType,
  sizeBytes: file.sizeBytes,
  kind: file.kind
})

export const captureAssistantFile = async (
  services: CodevisorServerServices,
  input:
    | { readonly path: string }
    | { readonly data: Buffer; readonly name: string; readonly mimeType: string },
  existing: ReadonlyArray<AttachmentRef> = [],
  fileId: string = randomUUID()
): Promise<AttachmentRef> => {
  if ("path" in input && !(await stat(input.path)).isFile())
    throw new Error("Attachment path is not a regular file")
  const stored =
    "path" in input
      ? await services.attachments.putStream(createReadStream(input.path))
      : await services.attachments.put(input.data)
  for (const ref of existing) {
    const metadata = await run(services.db.getFileMetadata(ref.fileId))
    if (metadata?.sha256 === stored.sha256) return ref
  }
  const name = "path" in input ? basename(input.path) : input.name
  const mimeType = "path" in input ? filesystemMimeType(input.path) : input.mimeType
  return attachmentRef(
    await run(
      services.db.createDiskFile({
        id: fileId,
        name,
        mimeType,
        sizeBytes: stored.sizeBytes,
        sha256: stored.sha256,
        kind: mimeType.startsWith("image/") ? "image" : "file",
        createdAt: new Date().toISOString()
      })
    )
  )
}
