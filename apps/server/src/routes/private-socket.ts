import { lstatSync, realpathSync, type Stats } from "node:fs"
import { basename, dirname, join } from "node:path"

export type PrivateSocketProblem = "missing" | "exposed"

export type PrivateSocket =
  | { readonly path: string; readonly problem?: undefined }
  | { readonly problem: PrivateSocketProblem; readonly path?: undefined }

export const privateSocket = (configured: string, uid: number = ownUid()): PrivateSocket => {
  const folder = realFolder(dirname(configured))
  if (folder === undefined) return { problem: "missing" }

  const path = join(folder, basename(configured))
  const socket = entryAt(path)
  if (socket === undefined) return { problem: "missing" }
  if (!opensOnlyFor(socket, uid)) return { problem: "exposed" }
  if (!foldersAbove(path).every((above) => keepsOthersOut(above, uid)))
    return { problem: "exposed" }

  return { path }
}

const othersMayOpen = 0o077
const othersMayWrite = 0o022
const sticky = 0o1000
const rootUid = 0
const noUid = -1

const ownUid = (): number => process.getuid?.() ?? noUid

const opensOnlyFor = (socket: Stats, uid: number): boolean =>
  socket.isSocket() && socket.uid === uid && (socket.mode & othersMayOpen) === 0

const keepsOthersOut = (folder: string, uid: number): boolean => {
  const entry = entryAt(folder)
  if (entry === undefined || !entry.isDirectory()) return false
  if (entry.uid !== uid && entry.uid !== rootUid) return false

  return (entry.mode & othersMayWrite) === 0 || (entry.mode & sticky) !== 0
}

const foldersAbove = (path: string): ReadonlyArray<string> => {
  const folder = dirname(path)
  if (folder === path) return []

  return [folder, ...foldersAbove(folder)]
}

const realFolder = (folder: string): string | undefined => {
  try {
    return realpathSync(folder)
  } catch {
    return undefined
  }
}

const entryAt = (path: string): Stats | undefined => {
  try {
    return lstatSync(path)
  } catch {
    return undefined
  }
}
