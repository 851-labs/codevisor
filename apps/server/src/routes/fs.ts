import { FsMkdirRequest, type FsListResponse } from "@codevisor/api"
import { createReadStream, existsSync, statSync, type Stats } from "node:fs"
import { mkdir, readdir } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { basename, dirname, extname, isAbsolute, join, resolve as resolvePath } from "node:path"
import { fileURLToPath } from "node:url"
import {
  HttpFailure,
  readSchema,
  requestedByteRange,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

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

const filesystemMimeType = (path: string): string =>
  filesystemMimeTypes[extname(path).toLowerCase()] ?? "application/octet-stream"

/// Expands "~" / "~/…" against the server's home and requires an absolute
/// result — shared by every fs surface so path rules cannot drift.
const expandFsPath = (requested: string): string => {
  const home = homedir()
  const expanded =
    requested === "~"
      ? home
      : requested.startsWith("~/")
        ? join(home, requested.slice(2))
        : requested
  if (!expanded.startsWith("/")) {
    throw new HttpFailure(400, `Path must be absolute: ${requested}`, "invalid_path")
  }
  return resolvePath(expanded)
}

export const routeFs = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname === "/v1/fs/file" && (request.method === "GET" || request.method === "HEAD")) {
    const requested = url.searchParams.get("path")
    if (requested === null || requested.length === 0) {
      throw new HttpFailure(400, "File path is required", "invalid_path")
    }
    let expanded: string
    try {
      expanded = requested.startsWith("file://")
        ? fileURLToPath(requested)
        : requested === "~"
          ? homedir()
          : requested.startsWith("~/")
            ? join(homedir(), requested.slice(2))
            : requested
    } catch {
      throw new HttpFailure(400, `Invalid file URL: ${requested}`, "invalid_path")
    }
    if (!isAbsolute(expanded)) {
      const sessionId = url.searchParams.get("sessionId")
      if (sessionId === null || sessionId.length === 0) {
        throw new HttpFailure(400, "sessionId is required for a relative file path", "invalid_path")
      }
      const session = await run(services.db.getSessionSummary(sessionId.toLowerCase()))
      /* v8 ignore next -- server-created local sessions always retain their project working directory. */
      if (session.cwd === undefined) {
        throw new HttpFailure(409, `Session has no working directory: ${sessionId}`, "missing_cwd")
      }
      expanded = resolvePath(session.cwd, expanded)
    }

    const path = resolvePath(expanded)
    const fallbacks = [
      path.replace(/#L\d+(?:-L?\d+)?$/, ""),
      path.replace(/:\d+(?::\d+)?$/, "")
    ].filter(
      (candidate, index, values) => candidate !== path && values.indexOf(candidate) === index
    )
    let resolved = path
    let info: Stats | undefined
    let lastError: unknown
    for (const candidate of [path, ...fallbacks]) {
      try {
        const candidateInfo = statSync(candidate)
        if (candidateInfo.isFile()) {
          resolved = candidate
          info = candidateInfo
          break
        }
        lastError = Object.assign(new Error(`Not a file: ${candidate}`), { code: "EISDIR" })
      } catch (cause) {
        lastError = cause
      }
    }
    if (info === undefined) {
      /* v8 ignore next -- every failed candidate records the filesystem error that determines the response. */
      const code = (lastError as NodeJS.ErrnoException | undefined)?.code ?? ""
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
    // Size plus sub-millisecond mtime precision is a cheap stable validator
    // for device-local preview caches. The file remains `no-store`: clients
    // explicitly revalidate it rather than treating a path as immutable.
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
    if (request.method === "HEAD") {
      response.end()
      return true
    }
    const stream = createReadStream(resolved, range === undefined ? {} : range)
    /* v8 ignore next -- requires the live file to disappear after validation but before the stream opens. */
    stream.once("error", (cause) => response.destroy(cause))
    stream.pipe(response)
    return true
  }

  // Creates a directory on this machine — the remote browser's "New
  // Folder". Same path rules as /v1/fs/list; recursive and idempotent for
  // directories, 409 when a non-directory occupies the path.
  if (url.pathname === "/v1/fs/mkdir" && request.method === "POST") {
    const body = await readSchema(request, FsMkdirRequest)
    const path = expandFsPath(body.path)
    try {
      await mkdir(path, { recursive: true })
    } catch (cause) {
      /* v8 ignore next -- mkdir errno failures always carry a code. */
      const code = (cause as NodeJS.ErrnoException).code ?? ""
      if (["EACCES", "EPERM"].includes(code)) {
        throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
      }
      // macOS reports EEXIST where Linux reports ENOTDIR for a file in the way.
      /* v8 ignore next -- the no-match fall-through is the ignored generic rethrow below. */
      if (["EEXIST", "ENOTDIR"].includes(code)) {
        throw new HttpFailure(409, `A file is in the way: ${path}`, "not_a_directory")
      }
      /* v8 ignore next 2 -- other mkdir failures (EIO etc.) fall through to the generic 500. */
      throw cause
    }
    writeJson(response, 201, { path })
    return true
  }

  if (request.method !== "GET" || url.pathname !== "/v1/fs/list") return false
  const requested = url.searchParams.get("path") ?? "~"
  const showHidden = url.searchParams.get("showHidden") === "true"
  const path = expandFsPath(requested)
  let names: Array<import("node:fs").Dirent>
  try {
    names = await readdir(path, { withFileTypes: true })
  } catch (cause) {
    /* v8 ignore next -- readdir errno failures always carry a code. */
    const code = (cause as NodeJS.ErrnoException).code ?? ""
    if (code === "ENOENT") {
      throw new HttpFailure(404, `No such directory: ${path}`, "not_found")
    }
    if (["EACCES", "EPERM"].includes(code)) {
      throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
    }
    /* v8 ignore start -- the not-ENOTDIR arm covers other readdir failures (EIO etc.) falling through to the generic 500. */
    if (code === "ENOTDIR") {
      throw new HttpFailure(400, `Not a directory: ${path}`, "not_a_directory")
    }
    throw cause
    /* v8 ignore stop */
  }
  const entries = names
    .filter((entry) => {
      if (!showHidden && entry.name.startsWith(".")) return false
      if (entry.isDirectory()) return true
      // Follow directory symlinks (common for workspace layouts); skip broken ones.
      if (!entry.isSymbolicLink()) return false
      try {
        return statSync(join(path, entry.name)).isDirectory()
      } catch {
        return false
      }
    })
    .map((entry) => ({
      name: entry.name,
      path: join(path, entry.name),
      isGitRepo: existsSync(join(path, entry.name, ".git"))
    }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }))
  const body: FsListResponse = {
    path,
    parent: path === "/" ? null : dirname(path),
    entries
  }
  writeJson(response, 200, body)
  return true
}
