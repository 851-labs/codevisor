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
import { sendFilesystemArchive } from "./fs-archive.js"
import { directoryEntries } from "./fs-directory-entries.js"
import { deleteFilesystemItems, moveFilesystemItem } from "./fs-edit.js"
import { serveFilesystemFile } from "./fs-file.js"
import { claimKeptBothPath } from "./fs-kept-both.js"
import { expandFsPath } from "./fs-paths.js"
import { readTextFile } from "./fs-read.js"
import { receiveFilesystemFile } from "./fs-upload.js"
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
  if (url.pathname === "/v1/fs/file" && request.method === "PUT")
    return receiveFilesystemFile(request, response, url)
  if (url.pathname === "/v1/fs/archive" && request.method === "GET")
    return sendFilesystemArchive(request, response, url)
  if (url.pathname === "/v1/fs/read" && request.method === "GET") return readTextFile(response, url)
  if (url.pathname === "/v1/fs/move" && request.method === "POST")
    return moveFilesystemItem(request, response)
  if (url.pathname === "/v1/fs/delete" && request.method === "POST")
    return deleteFilesystemItems(request, response)
  if (url.pathname === "/v1/fs/mkdir" && request.method === "POST")
    return createFilesystemDirectory(request, response)
  if (request.method !== "GET" || url.pathname !== "/v1/fs/list") return false
  return listFilesystemDirectory(response, url)
}

const throwFilesystemMkdirFailure = (path: string, cause: unknown): never => {
  if (cause instanceof HttpFailure) throw cause
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
  const requested = expandFsPath(body.path)
  let path: string
  try {
    path = await makeDirectory(requested, body.conflict)
  } catch (cause) {
    return throwFilesystemMkdirFailure(requested, cause)
  }
  writeJson(response, 201, { path })
  return true
}

const makeDirectory = async (
  path: string,
  conflict: FsMkdirRequest["conflict"]
): Promise<string> => {
  if (conflict === undefined) {
    await mkdir(path, { recursive: true })
    return path
  }
  await mkdir(dirname(path), { recursive: true })
  return claimKeptBothPath(path, "folder", createSingleDirectory)
}

const createSingleDirectory = async (path: string): Promise<void> => {
  await mkdir(path)
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
