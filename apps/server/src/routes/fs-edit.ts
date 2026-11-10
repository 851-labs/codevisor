import { lstat, rename, rm } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { dirname } from "node:path"

import { FsDeleteRequest, FsMoveRequest } from "@codevisor/api"

import { HttpFailure, readSchema, writeJson } from "../server-context.js"
import { stringField } from "../unknown-values.js"
import { expandFsPath } from "./fs-paths.js"

export const moveFilesystemItem = async (
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const body = await readSchema(request, FsMoveRequest)
  const from = expandFsPath(body.from)
  const to = expandFsPath(body.to)

  await requireFreeDestination(from, to)
  await renameOrFail(from, to)

  writeJson(response, 200, { path: to })
  return true
}

export const deleteFilesystemItems = async (
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const body = await readSchema(request, FsDeleteRequest)
  const paths = body.paths.map(expandFsPath)
  paths.forEach(refuseProtectedPath)

  for (const path of paths) await removeOrFail(path)

  writeJson(response, 200, { deleted: paths })
  return true
}

const requireFreeDestination = async (from: string, to: string): Promise<void> => {
  const existing = await lstat(to).catch(() => undefined)
  if (existing === undefined) return
  if (await isSameItem(from, existing)) return
  throw new HttpFailure(409, `Something is already named ${to}`, "name_taken")
}

const isSameItem = async (
  from: string,
  existing: { readonly dev: number; readonly ino: number }
): Promise<boolean> => {
  const source = await lstat(from).catch(() => undefined)
  return source !== undefined && source.dev === existing.dev && source.ino === existing.ino
}

const renameOrFail = async (from: string, to: string): Promise<void> => {
  try {
    await rename(from, to)
  } catch (cause) {
    throwEditFailure(from, cause)
  }
}

const refuseProtectedPath = (path: string): void => {
  const isProtected = path === dirname(path) || path === homedir()
  if (isProtected) throw new HttpFailure(400, `Refusing to delete ${path}`, "protected_path")
}

const removeOrFail = async (path: string): Promise<void> => {
  try {
    await rm(path, { recursive: true })
  } catch (cause) {
    if (stringField(cause, "code") === "ENOENT") return
    throwEditFailure(path, cause)
  }
}

const throwEditFailure = (path: string, cause: unknown): never => {
  const code = stringField(cause, "code") ?? ""
  if (code === "ENOENT") throw new HttpFailure(404, `No such file or folder: ${path}`, "not_found")
  if (["EACCES", "EPERM", "EROFS"].includes(code)) {
    throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
  }
  if (["EEXIST", "ENOTEMPTY", "ENOTDIR", "EISDIR", "EINVAL", "EXDEV"].includes(code)) {
    throw new HttpFailure(409, `Can't move ${path} there`, "path_conflict")
  }
  throw cause
}
