import { realpath, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { sep } from "node:path"

import { MAX_UPLOAD_BYTES } from "@codevisor/api"

export const capturablePath = async (
  path: string,
  cwd: string | undefined
): Promise<string | undefined> => {
  const real = await realpath(path).catch(() => undefined)
  if (real === undefined) return undefined

  const roots = await captureRoots(cwd)
  if (!roots.some((root) => isInside(real, root))) return undefined

  const info = await stat(real)
  if (!info.isFile() || info.size > MAX_UPLOAD_BYTES) return undefined
  return real
}

const temporaryFolders = [tmpdir(), "/tmp", "/var/folders"]

const captureRoots = async (cwd: string | undefined): Promise<ReadonlyArray<string>> => {
  const candidates = [cwd, ...temporaryFolders].filter((folder) => folder !== undefined)
  const resolved = await Promise.all(candidates.map((folder) => realpath(folder).catch(() => "")))
  return resolved.filter((folder) => folder !== "")
}

const isInside = (path: string, root: string): boolean => path.startsWith(root + sep)
