import { createReadStream, statSync, type Stats } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { basename, extname, isAbsolute, join, resolve as resolvePath } from "node:path"
import { fileURLToPath } from "node:url"

import { mediaPreview } from "../infra/media-previews.js"
import {
  HttpFailure,
  requestedByteRange,
  run,
  type ByteRange,
  type CodevisorServerServices
} from "../server-context.js"
import { stringField } from "../unknown-values.js"

const filesystemMimeTypes: Readonly<Record<string, string>> = {
  ".aac": "audio/aac",
  ".aiff": "audio/aiff",
  ".avi": "video/x-msvideo",
  ".bmp": "image/bmp",
  ".csv": "text/csv",
  ".doc": "application/msword",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".gif": "image/gif",
  ".heic": "image/heic",
  ".html": "text/html",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".json": "application/json",
  ".m4a": "audio/mp4",
  ".m4v": "video/mp4",
  ".md": "text/markdown",
  ".mov": "video/quicktime",
  ".mp3": "audio/mpeg",
  ".mp4": "video/mp4",
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".ppt": "application/vnd.ms-powerpoint",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ".svg": "image/svg+xml",
  ".tiff": "image/tiff",
  ".tsv": "text/tab-separated-values",
  ".txt": "text/plain",
  ".wav": "audio/wav",
  ".webm": "video/webm",
  ".webp": "image/webp",
  ".xls": "application/vnd.ms-excel",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".xml": "application/xml",
  ".zip": "application/zip"
}

export const filesystemMimeType = (path: string): string =>
  filesystemMimeTypes[extname(path).toLowerCase()] ?? "application/octet-stream"

const expandRequestedFilePath = (url: URL): string => {
  const requested = url.searchParams.get("path")
  if (requested === null || requested.length === 0) {
    throw new HttpFailure(400, "File path is required", "invalid_path")
  }
  try {
    if (requested.startsWith("file://")) return fileURLToPath(requested)
    if (requested === "~") return homedir()
    if (requested.startsWith("~/")) return join(homedir(), requested.slice(2))
    return requested
  } catch {
    throw new HttpFailure(400, `Invalid file URL: ${requested}`, "invalid_path")
  }
}

const throwFilesystemFileFailure = (path: string, lastError: unknown): never => {
  /* v8 ignore next */
  const code = stringField(lastError, "code") ?? ""
  if (code === "ENOENT") {
    throw new HttpFailure(404, `No such file: ${path}`, "not_found")
  }
  if (["EACCES", "EPERM"].includes(code)) {
    throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
  }
  if (code === "EISDIR") {
    throw new HttpFailure(400, `Not a file: ${path}`, "not_a_file")
  }
  throw lastError
}

const serveFilesystemPreview = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  resolved: string,
  info: Stats
): Promise<boolean> => {
  const preview = await mediaPreview(
    resolved,
    filesystemMimeType(resolved),
    services.attachments.root,
    `${resolved}:${info.size}:${info.mtimeMs}`
  )
  response.writeHead(200, {
    "Content-Type": "image/png",
    "Content-Length": preview.length,
    "Cache-Control": "private, no-store"
  })
  response.end(preview)
  return true
}

const writeFilesystemFileHeaders = (
  response: ServerResponse,
  resolved: string,
  info: Stats,
  range: ByteRange | undefined,
  contentLength: number
): void => {
  const entityTag = `"${info.size.toString(16)}-${Math.round(info.mtimeMs * 1_000).toString(16)}"`
  response.writeHead(range === undefined ? 200 : 206, {
    "Accept-Ranges": "bytes",
    "Cache-Control": "private, no-store",
    "Content-Disposition": `inline; filename*=UTF-8''${encodeURIComponent(basename(resolved))}`,
    "Content-Length": contentLength,
    ETag: entityTag,
    ...(range === undefined
      ? {}
      : { "Content-Range": `bytes ${range.start}-${range.end}/${info.size}` }),
    "Content-Type": filesystemMimeType(resolved),
    "Last-Modified": info.mtime.toUTCString()
  })
}

const streamFilesystemFile = (
  request: IncomingMessage,
  response: ServerResponse,
  resolved: string,
  info: Stats
): boolean => {
  const range = requestedByteRange(request.headers.range, info.size)
  if (range === "invalid") {
    response.writeHead(416, {
      "Accept-Ranges": "bytes",
      "Content-Range": `bytes */${info.size}`
    })
    response.end()
    return true
  }
  const contentLength = range === undefined ? info.size : range.end - range.start + 1
  writeFilesystemFileHeaders(response, resolved, info, range, contentLength)
  if (request.method === "HEAD") {
    response.end()
    return true
  }
  const stream = createReadStream(resolved, range === undefined ? {} : range)
  /* v8 ignore next */
  stream.once("error", (cause) => response.destroy(cause))
  stream.pipe(response)
  return true
}

export const serveFilesystemFile = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  let expanded = expandRequestedFilePath(url)
  if (!isAbsolute(expanded)) {
    const sessionId = url.searchParams.get("sessionId")
    if (sessionId === null || sessionId.length === 0) {
      throw new HttpFailure(400, "sessionId is required for a relative file path", "invalid_path")
    }
    const session = await run(services.db.getSessionSummary(sessionId.toLowerCase()))
    /* v8 ignore next */
    if (session.cwd === undefined) {
      throw new HttpFailure(409, `Session has no working directory: ${sessionId}`, "missing_cwd")
    }
    expanded = resolvePath(session.cwd, expanded)
  }

  const path = resolvePath(expanded)
  const fallbacks = [
    path.replace(/#L\d+(?:-L?\d+)?$/, ""),
    path.replace(/:\d+(?::\d+)?$/, "")
  ].filter((candidate, index, values) => candidate !== path && values.indexOf(candidate) === index)
  let resolved = path
  const resolveFileInfo = (): Stats => {
    let lastError: unknown
    for (const candidate of [path, ...fallbacks]) {
      try {
        const candidateInfo = statSync(candidate)
        if (candidateInfo.isFile()) {
          resolved = candidate
          return candidateInfo
        }
        lastError = Object.assign(new Error(`Not a file: ${candidate}`), { code: "EISDIR" })
      } catch (cause) {
        lastError = cause
      }
    }
    return throwFilesystemFileFailure(path, lastError)
  }
  const info = resolveFileInfo()

  if (request.method === "GET" && url.searchParams.get("preview") === "1")
    return serveFilesystemPreview(services, response, resolved, info)
  return streamFilesystemFile(request, response, resolved, info)
}
