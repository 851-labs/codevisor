import { randomUUID } from "node:crypto"
import { createWriteStream } from "node:fs"
import { mkdir, open, rename, rm } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { basename, dirname, join } from "node:path"
import { pipeline } from "node:stream/promises"

import { HttpFailure, writeJson } from "../server-context.js"
import { stringField } from "../unknown-values.js"
import { claimKeptBothPath } from "./fs-kept-both.js"
import { expandFsPath } from "./fs-paths.js"

type UploadConflict = "keepBoth" | "replace"

export const receiveFilesystemFile = async (
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const target = expandFsPath(url.searchParams.get("path") ?? "")
  const conflict = uploadConflict(url)

  await createParentFolder(target)
  const staged = await stageUpload(request, target)
  const path = await placeStagedUpload(staged, target, conflict)

  writeJson(response, 201, { path })
  return true
}

const uploadConflict = (url: URL): UploadConflict => {
  const requested = url.searchParams.get("conflict") ?? "keepBoth"
  if (requested === "keepBoth" || requested === "replace") return requested
  throw new HttpFailure(400, `Unknown conflict option: ${requested}`, "invalid_conflict")
}

const createParentFolder = async (target: string): Promise<void> => {
  try {
    await mkdir(dirname(target), { recursive: true })
  } catch (cause) {
    throwFilesystemWriteFailure(dirname(target), cause)
  }
}

const stageUpload = async (request: IncomingMessage, target: string): Promise<string> => {
  const staged = join(dirname(target), `.${basename(target)}.${randomUUID()}.codevisor-upload`)
  try {
    await pipeline(request, createWriteStream(staged, { flags: "wx" }))
    return staged
  } catch (cause) {
    await discard(staged)
    return throwFilesystemWriteFailure(target, cause)
  }
}

const placeStagedUpload = async (
  staged: string,
  target: string,
  conflict: UploadConflict
): Promise<string> => {
  let reserved: string | undefined
  try {
    const path = await placement(target, conflict)
    if (conflict === "keepBoth") reserved = path
    await rename(staged, path)
    return path
  } catch (cause) {
    await discard(staged)
    if (reserved !== undefined) await discard(reserved)
    return throwFilesystemWriteFailure(target, cause)
  }
}

const placement = async (target: string, conflict: UploadConflict): Promise<string> => {
  if (conflict === "replace") return target
  return claimKeptBothPath(target, "file", reserveEmptyFile)
}

const reserveEmptyFile = async (candidate: string): Promise<void> => {
  const handle = await open(candidate, "wx")
  await handle.close()
}

const discard = (path: string): Promise<void> => rm(path, { force: true })

const throwFilesystemWriteFailure = (path: string, cause: unknown): never => {
  if (cause instanceof HttpFailure) throw cause
  const code = stringField(cause, "code") ?? ""
  if (["EACCES", "EPERM", "EROFS"].includes(code)) {
    throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
  }
  if (["EEXIST", "ENOTDIR", "EISDIR", "ENOTEMPTY"].includes(code)) {
    throw new HttpFailure(409, `Something is in the way: ${path}`, "path_conflict")
  }
  if (["ENOSPC", "EDQUOT"].includes(code)) {
    throw new HttpFailure(507, `Not enough disk space for ${path}`, "no_space")
  }
  throw cause
}
