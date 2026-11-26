import { lstatSync, realpathSync, type Stats } from "node:fs"
import { basename, dirname, join } from "node:path"

export type PrivateSocketProblem = "missing" | "foreign" | "exposed"

export type PrivateSocket =
  | { readonly path: string; readonly problem?: undefined }
  | {
      readonly problem: PrivateSocketProblem
      readonly detail: string
      readonly path?: undefined
    }

export const privateSocket = (configured: string, uid: number = ownUid()): PrivateSocket => {
  const folder = reading(() => realpathSync(dirname(configured)))
  if (isUnreadable(folder)) return unreadable(folder, dirname(configured))

  const path = join(folder, basename(configured))
  const socket = reading(() => lstatSync(path))
  if (isUnreadable(socket)) return unreadable(socket, path)
  if (!socket.isSocket()) return { problem: "foreign", detail: `${path} is not a socket` }
  if (socket.uid !== uid) return { problem: "foreign", detail: `${path} ${ownership(socket)}` }
  if ((socket.mode & othersMayOpen) !== 0)
    return { problem: "exposed", detail: `other accounts can open ${path} (${access(socket)})` }

  const open = foldersAbove(path).find((above) => !keepsOthersOut(above, uid))
  if (open !== undefined) return { problem: "exposed", detail: `${open} ${whyOpen(open)}` }

  return { path }
}

type Unreadable = "missing" | "foreign"

const othersMayOpen = 0o077
const othersMayWrite = 0o022
const sticky = 0o1000
const permissionBits = 0o7777
const rootUid = 0
const noUid = -1
const notAllowed = new Set(["EACCES", "EPERM"])

const ownUid = (): number => process.getuid?.() ?? noUid

const reading = <Found>(read: () => Found): Found | Unreadable => {
  try {
    return read()
  } catch (error) {
    return isNotAllowed(error) ? "foreign" : "missing"
  }
}

const isNotAllowed = (error: unknown): boolean =>
  error instanceof Error && "code" in error && notAllowed.has(String(error.code))

const isUnreadable = (found: unknown): found is Unreadable =>
  found === "missing" || found === "foreign"

const unreadable = (problem: Unreadable, path: string): PrivateSocket => ({
  problem,
  detail: problem === "missing" ? `nothing at ${path}` : `access to ${path} was denied`
})

const access = (entry: Stats): string => `mode ${(entry.mode & permissionBits).toString(8)}`

const ownership = (entry: Stats): string => `belongs to uid ${entry.uid}`

const keepsOthersOut = (folder: string, uid: number): boolean => {
  const entry = reading(() => lstatSync(folder))
  if (isUnreadable(entry) || !entry.isDirectory()) return false
  if (entry.uid !== uid && entry.uid !== rootUid) return false

  return (entry.mode & othersMayWrite) === 0 || (entry.mode & sticky) !== 0
}

const whyOpen = (folder: string): string => {
  const entry = reading(() => lstatSync(folder))
  if (isUnreadable(entry)) return "can't be checked"

  return `can be changed by other accounts (${access(entry)}, ${ownership(entry)})`
}

const foldersAbove = (path: string): ReadonlyArray<string> => {
  const folder = dirname(path)
  if (folder === path) return []

  return [folder, ...foldersAbove(folder)]
}
