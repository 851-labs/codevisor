import type { FileMetadata } from "@codevisor/api"
import { makeAttachmentStore } from "@codevisor/db"
import { randomUUID } from "node:crypto"
import { createReadStream } from "node:fs"
import { realpath, stat } from "node:fs/promises"
import { basename, dirname, join } from "node:path"

/** Only completed files produced in the native recorder's private directory are importable. */
export const makeRecordingPublisher = (
  dataDir: string,
  createFile: (metadata: FileMetadata) => Promise<unknown>
) => {
  const store = makeAttachmentStore(dataDir)
  return async (file: { readonly path: string; readonly name: string }) => {
    const root = await realpath(join(dataDir, "computer-use-recordings"))
    const path = await realpath(file.path)
    const info = await stat(path)
    if (dirname(path) !== root || !path.endsWith(".mp4") || !info.isFile() || info.size === 0)
      throw new Error("Only completed Computer Use MP4 recordings can be attached")
    const stored = await store.putStream(createReadStream(path))
    const metadata: FileMetadata = {
      id: randomUUID(),
      name: basename(file.name),
      mimeType: "video/mp4",
      sizeBytes: stored.sizeBytes,
      sha256: stored.sha256,
      kind: "file",
      createdAt: new Date().toISOString()
    }
    await createFile(metadata)
    return {
      fileId: metadata.id,
      path: await store.materialize(metadata),
      sizeBytes: metadata.sizeBytes
    }
  }
}
