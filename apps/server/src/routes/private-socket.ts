import { lstatSync, realpathSync } from "node:fs"
import { basename, dirname, join } from "node:path"

export type PrivateSocketProblem = "missing" | "foreign" | "exposed"

export type PrivateSocket =
  | { readonly path: string; readonly problem?: undefined }
  | { readonly problem: PrivateSocketProblem; readonly path?: undefined }

export const privateSocket = (configured: string, uid: number = ownUid()): PrivateSocket => {
  const folder = reading(() => realpathSync(dirname(configured)))
  if (isUnreadable(folder)) return { problem: folder }

  const path = join(folder, basename(configured))
  const socket = reading(() => lstatSync(path))
  if (isUnreadable(socket)) return { problem: socket }
  if (!socket.isSocket() || socket.uid !== uid) return { problem: "foreign" }
  if ((socket.mode & othersMayOpen) !== 0) return { problem: "exposed" }
  if (!foldersAbove(path).every((above) => keepsOthersOut(above, uid)))
    return { problem: "exposed" }

  return { path }
}

type Unreadable = "missing" | "foreign"

const othersMayOpen = 0o077
const othersMayWrite = 0o022
const sticky = 0o1000
const rootUid = 0
const noUid = -1
const nothingThere = new Set(["ENOENT", "ENOTDIR"])

const ownUid = (): number => process.getuid?.() ?? noUid

const reading = <Found>(read: () => Found): Found | Unreadable => {
  try {
    return read()
  } catch (error) {
    return isNothingThere(error) ? "missing" : "foreign"
  }
}

const isNothingThere = (error: unknown): boolean =>
  error instanceof Error && "code" in error && nothingThere.has(String(error.code))

const isUnreadable = (found: unknown): found is Unreadable =>
  found === "missing" || found === "foreign"

const keepsOthersOut = (folder: string, uid: number): boolean => {
  const entry = reading(() => lstatSync(folder))
  if (isUnreadable(entry) || !entry.isDirectory()) return false
  if (entry.uid !== uid && entry.uid !== rootUid) return false

  return (entry.mode & othersMayWrite) === 0 || (entry.mode & sticky) !== 0
}

const foldersAbove = (path: string): ReadonlyArray<string> => {
  const folder = dirname(path)
  if (folder === path) return []

  return [folder, ...foldersAbove(folder)]
}
