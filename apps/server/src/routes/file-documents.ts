import { createHash, randomUUID } from "node:crypto"
import {
  accessSync,
  closeSync,
  constants,
  fchmodSync,
  fsyncSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync
} from "node:fs"
import { readdir } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { basename, dirname, isAbsolute, join, resolve } from "node:path"

import { HttpFailure, readJson, writeJson } from "../server-context.js"
import { searchFileEntries } from "./file-search.js"

const textLimit = 4 * 1024 * 1024
const revision = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex")

function requestedPath(url: URL): string {
  const value = url.searchParams.get("path") ?? ""
  const expanded =
    value === "~" ? homedir() : value.startsWith("~/") ? join(homedir(), value.slice(2)) : value
  if (!isAbsolute(expanded))
    throw new HttpFailure(400, "Choose an absolute file path.", "invalid_path")
  return resolve(expanded)
}

function textContent(bytes: Buffer): string | null {
  if (bytes.includes(0)) return null
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes)
  } catch {
    return null
  }
}

function snapshot(path: string) {
  const canonicalPath = realpathSync(path)
  const info = statSync(canonicalPath)
  if (!info.isFile()) throw new HttpFailure(400, "This path points to a folder.", "not_a_file")
  let writable = info.nlink === 1
  try {
    accessSync(canonicalPath, constants.W_OK)
    accessSync(dirname(canonicalPath), constants.W_OK)
  } catch {
    writable = false
  }
  const bytes = info.size <= textLimit ? readFileSync(canonicalPath) : null
  const content = bytes === null ? null : textContent(bytes)
  return {
    path: canonicalPath,
    content,
    version: bytes === null ? `${info.size}:${info.mtimeMs}` : revision(bytes),
    size: info.size,
    writable: writable && content !== null,
    reason:
      info.size > textLimit
        ? "This file is too large to edit. The editor supports files up to 4 MB."
        : content === null
          ? "This file uses a binary or unsupported text format."
          : !writable
            ? "This file is read-only."
            : null
  }
}

function save(path: string, input: unknown) {
  if (
    typeof input !== "object" ||
    input === null ||
    !("content" in input) ||
    !("version" in input) ||
    typeof input.content !== "string" ||
    typeof input.version !== "string"
  ) {
    throw new HttpFailure(
      400,
      "File contents and the original version are required.",
      "invalid_request"
    )
  }
  const bytes = Buffer.from(input.content, "utf8")
  if (bytes.length > textLimit || textContent(bytes) === null) {
    throw new HttpFailure(413, "Save a UTF-8 text file smaller than 4 MB.", "file_too_large")
  }
  // No asynchronous boundary between checking the revision and committing:
  // concurrent saves through this server cannot both accept the same base.
  // Resolve symlinks so atomic replacement preserves the link itself.
  const current = snapshot(path)
  if (current.version !== input.version) {
    throw new HttpFailure(
      409,
      "This file changed on the machine. Review the changes before saving.",
      "file_conflict"
    )
  }
  if (current.reason !== null) throw new HttpFailure(403, current.reason, "permission_denied")
  const temporary = join(dirname(current.path), `.${basename(current.path)}.${randomUUID()}.tmp`)
  let fd: number | undefined
  try {
    const info = statSync(current.path)
    fd = openSync(temporary, "wx", info.mode & 0o777)
    writeFileSync(fd, bytes)
    fchmodSync(fd, info.mode & 0o777)
    fsyncSync(fd)
    closeSync(fd)
    fd = undefined
    if (revision(readFileSync(current.path)) !== input.version) {
      throw new HttpFailure(
        409,
        "This file changed while saving. Your edits are still available.",
        "file_conflict"
      )
    }
    renameSync(temporary, current.path)
  } finally {
    if (fd !== undefined) closeSync(fd)
    try {
      unlinkSync(temporary)
    } catch {
      /* Renamed successfully, or never created. */
    }
  }
  return snapshot(current.path)
}

export async function routeFileDocuments(
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> {
  if (!["/v1/fs/document", "/v1/fs/entries", "/v1/fs/search"].includes(url.pathname)) return false
  try {
    const path = requestedPath(url)
    if (url.pathname === "/v1/fs/search" && request.method === "GET") {
      const controller = new AbortController()
      const cancel = () => controller.abort()
      response.once("close", cancel)
      try {
        const result = await searchFileEntries(path, url.searchParams.get("query") ?? "", {
          signal: controller.signal
        })
        response.setHeader("Cache-Control", "private, no-store")
        writeJson(response, 200, result)
      } finally {
        response.off("close", cancel)
      }
      return true
    }
    if (url.pathname === "/v1/fs/entries" && request.method === "GET") {
      const entries = await readdir(path, { withFileTypes: true })
      const visible = entries.filter(
        (entry) => url.searchParams.get("showHidden") === "true" || !entry.name.startsWith(".")
      )
      const rows = visible
        .flatMap((entry) => {
          try {
            const target = join(path, entry.name)
            const info = statSync(target)
            if (!info.isDirectory() && !info.isFile()) return []
            return [
              {
                name: entry.name,
                path: target,
                isDirectory: info.isDirectory(),
                isSymbolicLink: entry.isSymbolicLink()
              }
            ]
          } catch {
            return []
          }
        })
        .toSorted(
          (a, b) =>
            Number(b.isDirectory) - Number(a.isDirectory) ||
            a.name.localeCompare(b.name, "en", { numeric: true })
        )
      writeJson(response, 200, { path, entries: rows })
      return true
    }
    if (url.pathname === "/v1/fs/document" && request.method === "GET") {
      const value = snapshot(path)
      response.setHeader("Cache-Control", "private, no-store")
      if (url.searchParams.get("version") === value.version)
        writeJson(response, 200, { unchanged: true })
      else writeJson(response, 200, value)
      return true
    }
    if (url.pathname === "/v1/fs/document" && request.method === "PUT") {
      const body = await readJson(request)
      writeJson(response, 200, save(path, body))
      return true
    }
    throw new HttpFailure(405, "This file operation is not supported.", "method_not_allowed")
  } catch (error) {
    if (error instanceof HttpFailure) throw error
    const code = (error as NodeJS.ErrnoException).code
    if (code === "ENOENT")
      throw new HttpFailure(404, "This file has been moved or deleted.", "not_found")
    if (code === "EACCES" || code === "EPERM")
      throw new HttpFailure(
        403,
        "You don’t have permission to access this file.",
        "permission_denied"
      )
    if (code === "ENOTDIR")
      throw new HttpFailure(400, "This path is not a folder.", "not_a_directory")
    throw error
  }
}
