import { mkdir, readdir } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { dirname } from "node:path"

import { FsMkdirRequest, type FsListResponse } from "@codevisor/api"

import {
  HttpFailure,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"
import { stringField } from "../unknown-values.js"
import { routeFileDocuments } from "./file-documents.js"
import { directoryEntries } from "./fs-directory-entries.js"
import { serveFilesystemFile } from "./fs-file.js"
import { expandFsPath } from "./fs-paths.js"
import { routeGitReview } from "./git-review.js"

export { filesystemMimeType } from "./fs-file.js"

export const routeFs = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (await routeFileDocuments(request, response, url)) return true
  if (await routeGitReview(services, request, response, url)) return true
  if (url.pathname === "/v1/fs/file" && (request.method === "GET" || request.method === "HEAD"))
    return serveFilesystemFile(services, request, response, url)
  if (url.pathname === "/v1/fs/mkdir" && request.method === "POST")
    return createFilesystemDirectory(request, response)
  if (request.method !== "GET" || url.pathname !== "/v1/fs/list") return false
  return listFilesystemDirectory(response, url)
}

const throwFilesystemMkdirFailure = (path: string, cause: unknown): never => {
  /* v8 ignore next */
  const code = stringField(cause, "code") ?? ""
  if (["EACCES", "EPERM"].includes(code)) {
    throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
  }
  /* v8 ignore next */
  if (["EEXIST", "ENOTDIR"].includes(code)) {
    throw new HttpFailure(409, `A file is in the way: ${path}`, "not_a_directory")
  }
  /* v8 ignore next 2 */
  throw cause
}

const createFilesystemDirectory = async (
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const body = await readSchema(request, FsMkdirRequest)
  const path = expandFsPath(body.path)
  try {
    await mkdir(path, { recursive: true })
  } catch (cause) {
    return throwFilesystemMkdirFailure(path, cause)
  }
  writeJson(response, 201, { path })
  return true
}

const throwFilesystemListFailure = (path: string, cause: unknown): never => {
  /* v8 ignore next */
  const code = stringField(cause, "code") ?? ""
  if (code === "ENOENT") {
    throw new HttpFailure(404, `No such directory: ${path}`, "not_found")
  }
  if (["EACCES", "EPERM"].includes(code)) {
    throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
  }
  /* v8 ignore start */
  if (code === "ENOTDIR") {
    throw new HttpFailure(400, `Not a directory: ${path}`, "not_a_directory")
  }
  throw cause
  /* v8 ignore stop */
}

const listFilesystemDirectory = async (response: ServerResponse, url: URL): Promise<boolean> => {
  const requested = url.searchParams.get("path") ?? "~"
  const showHidden = url.searchParams.get("showHidden") === "true"
  const path = expandFsPath(requested)
  let names: Array<import("node:fs").Dirent>
  try {
    names = await readdir(path, { withFileTypes: true })
  } catch (cause) {
    return throwFilesystemListFailure(path, cause)
  }
  const entries = directoryEntries(path, names, showHidden)
  const body: FsListResponse = {
    path,
    parent: path === "/" ? null : dirname(path),
    entries
  }
  writeJson(response, 200, body)
  return true
}
