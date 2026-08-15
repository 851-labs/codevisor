import { randomUUID } from "node:crypto"
import type { FileMetadata } from "@codevisor/api"
import { createReadStream } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  attachmentDiskFile,
  matchRoute,
  requestedByteRange,
  run,
  sanitizeFileName,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

const IMAGE_MAGIC_BYTES: ReadonlyArray<readonly [ReadonlyArray<number>, number]> = [
  [[0x89, 0x50, 0x4e, 0x47], 0], // png
  [[0xff, 0xd8, 0xff], 0], // jpeg
  [[0x47, 0x49, 0x46, 0x38], 0], // gif
  [[0x57, 0x45, 0x42, 0x50], 8] // webp (RIFF....WEBP)
]

/// The stored kind drives UI treatment (thumbnail + lightbox vs file chip)
/// and provider mapping, so it is sniffed server-side rather than trusted
/// from the client's Content-Type alone.
const sniffAttachmentKind = (data: Buffer, mimeType: string): "image" | "file" => {
  const isImage =
    IMAGE_MAGIC_BYTES.some(
      ([magic, offset]) =>
        data.byteLength >= offset + magic.length &&
        magic.every((byte, index) => data[offset + index] === byte)
    ) || mimeType.startsWith("image/")
  return isImage ? "image" : "file"
}

export const routeFiles = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "POST" && url.pathname === "/v1/files") {
    const store = services.attachments
    const object = await store.putStream(request)
    const name = sanitizeFileName(url.searchParams.get("name") ?? "attachment")
    const mimeType =
      request.headers["content-type"]?.split(";")[0]?.trim() ?? "application/octet-stream"
    const metadata: FileMetadata = {
      id: randomUUID(),
      name,
      mimeType,
      sizeBytes: object.sizeBytes,
      sha256: object.sha256,
      kind: sniffAttachmentKind(object.header, mimeType),
      createdAt: new Date().toISOString()
    }
    await run(services.db.createDiskFile(metadata))
    writeJson(response, 201, metadata)
    return true
  }

  const fileId = matchRoute(url.pathname, "/v1/files/:id")
  if (fileId !== undefined && (request.method === "GET" || request.method === "HEAD")) {
    const file = await attachmentDiskFile(services, fileId)
    const range = requestedByteRange(request.headers.range, file.metadata.sizeBytes)
    if (range === "invalid") {
      response.writeHead(416, {
        "Accept-Ranges": "bytes",
        "Content-Range": `bytes */${file.metadata.sizeBytes}`
      })
      response.end()
      return true
    }
    const contentLength =
      range === undefined ? file.metadata.sizeBytes : range.end - range.start + 1
    response.writeHead(range === undefined ? 200 : 206, {
      // Files are immutable (content is stored once at upload), so clients
      // may cache aggressively.
      "Accept-Ranges": "bytes",
      "Cache-Control": "private, max-age=31536000, immutable",
      "Content-Disposition": `inline; filename*=UTF-8''${encodeURIComponent(file.metadata.name)}`,
      "Content-Length": contentLength,
      ...(range === undefined
        ? {}
        : { "Content-Range": `bytes ${range.start}-${range.end}/${file.metadata.sizeBytes}` }),
      "Content-Type": file.metadata.mimeType
    })
    if (request.method === "HEAD") {
      response.end()
      return true
    }
    const stream = createReadStream(file.path, range === undefined ? {} : range)
    /* v8 ignore next -- requires the immutable object to disappear after validation but before the stream opens. */
    stream.once("error", (cause) => response.destroy(cause))
    stream.pipe(response)
    return true
  }

  return false
}
