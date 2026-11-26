import { lstatSync, type Stats } from "node:fs"
import { dirname } from "node:path"

export type PrivateSocketProblem = "missing" | "exposed"

export const privateSocketProblem = (
  path: string,
  uid: number = ownUid()
): PrivateSocketProblem | undefined => {
  const socket = entryAt(path)
  if (socket === undefined) return "missing"
  if (!opensOnlyFor(socket, uid)) return "exposed"

  const directory = entryAt(dirname(path))
  if (directory === undefined || !keepsOthersOut(directory, uid)) return "exposed"

  return undefined
}

const othersMayOpen = 0o077
const othersMayWrite = 0o022
const noUid = -1

const ownUid = (): number => process.getuid?.() ?? noUid

const opensOnlyFor = (socket: Stats, uid: number): boolean =>
  socket.isSocket() && socket.uid === uid && (socket.mode & othersMayOpen) === 0

const keepsOthersOut = (directory: Stats, uid: number): boolean =>
  directory.isDirectory() && directory.uid === uid && (directory.mode & othersMayWrite) === 0

const entryAt = (path: string): Stats | undefined => {
  try {
    return lstatSync(path)
  } catch {
    return undefined
  }
}
