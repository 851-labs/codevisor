import { existsSync, statSync, type Dirent } from "node:fs"
import { join } from "node:path"

import type { FsListResponse } from "@codevisor/api"

const symlinkIsDirectory = (path: string): boolean => {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

const isListedDirectory = (path: string, entry: Dirent, showHidden: boolean): boolean => {
  if (!showHidden && entry.name.startsWith(".")) return false
  if (entry.isDirectory()) return true
  // Follow directory symlinks (common for workspace layouts); skip broken ones.
  if (!entry.isSymbolicLink()) return false
  return symlinkIsDirectory(join(path, entry.name))
}

export const directoryEntries = (
  path: string,
  names: Array<Dirent>,
  showHidden: boolean
): FsListResponse["entries"] =>
  names
    .filter((entry) => isListedDirectory(path, entry, showHidden))
    .map((entry) => ({
      name: entry.name,
      path: join(path, entry.name),
      isGitRepo: existsSync(join(path, entry.name, ".git"))
    }))
    .toSorted((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }))
