import { readdirSync, readFileSync, readlinkSync } from "node:fs"
import { join } from "node:path"

interface KernelTable {
  readonly name: string
  readonly absentWithoutIPv6?: boolean
}

interface Listener {
  readonly port: number
  readonly inode: string
}

const listening = "0A"
const inodeField = 9
const socketLink = /^socket:\[(\d+)\]$/
const kernelTables: ReadonlyArray<KernelTable> = [
  { name: "tcp" },
  { name: "tcp6", absentWithoutIPv6: true }
]

export const tcpPortsListenedOnBy = (pid: number, proc = "/proc"): ReadonlyArray<number> => {
  const own = socketsOf(pid, proc)
  return kernelTables
    .flatMap((table) => listeners(tableText(table, proc)))
    .filter((listener) => own.has(listener.inode))
    .map((listener) => listener.port)
}

export const holdsUnixSocket = (pid: number, socketPath: string, proc = "/proc"): boolean => {
  const own = socketsOf(pid, proc)
  return unixSockets(proc)
    .filter((socket) => socket.path === socketPath)
    .some((socket) => own.has(socket.inode))
}

export const listeners = (procNetTcp: string): ReadonlyArray<Listener> =>
  procNetTcp
    .split("\n")
    .slice(1)
    .map((line) => line.trim().split(/\s+/))
    .filter((fields) => fields[3] === listening && fields[1] !== undefined)
    .map((fields) => ({
      port: Number.parseInt(fields[1]!.slice(fields[1]!.lastIndexOf(":") + 1), 16),
      inode: fields[inodeField] ?? ""
    }))

const socketsOf = (pid: number, proc: string): ReadonlySet<string> => {
  const folder = join(proc, String(pid), "fd")
  try {
    return new Set(
      readdirSync(folder).flatMap((fd) => socketLink.exec(linkAt(join(folder, fd)))?.[1] ?? [])
    )
  } catch (error) {
    throw unchecked(folder, error)
  }
}

const unixInodeField = 6

const unixSockets = (proc: string): ReadonlyArray<{ inode: string; path: string }> => {
  const path = join(proc, "net", "unix")
  try {
    return readFileSync(path, "utf8")
      .split("\n")
      .slice(1)
      .map((line) => line.trim().split(/\s+/))
      .map((fields) => ({
        inode: fields[unixInodeField] ?? "",
        path: fields.slice(unixInodeField + 1).join(" ")
      }))
  } catch (error) {
    throw unchecked(path, error)
  }
}

const linkAt = (path: string): string => {
  try {
    return readlinkSync(path)
  } catch {
    return ""
  }
}

const tableText = (table: KernelTable, proc: string): string => {
  const path = join(proc, "net", table.name)
  try {
    return readFileSync(path, "utf8")
  } catch (error) {
    if (table.absentWithoutIPv6 === true && isMissing(error)) return ""

    throw unchecked(path, error)
  }
}

const unchecked = (path: string, cause: unknown): Error =>
  new Error(`Can't read ${path}, so the desktop's TCP ports can't be checked`, { cause })

const isMissing = (error: unknown): boolean =>
  error instanceof Error && "code" in error && error.code === "ENOENT"
