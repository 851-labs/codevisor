import { randomUUID } from "node:crypto"
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  rmdir,
  unlink,
  writeFile
} from "node:fs/promises"
import { dirname, join } from "node:path"
import { setTimeout as sleep } from "node:timers/promises"

export interface ArtifactLockOptions {
  readonly retryDelay?: () => Promise<unknown>
  readonly isProcessAlive?: (pid: number) => boolean | Promise<boolean>
  readonly pid?: number
}

const retryMilliseconds = 250
const renameConflicts: ReadonlySet<string> = new Set(["EEXIST", "ENOTEMPTY", "ENOTDIR", "EISDIR"])
const ownerName = /^owner-(\d+)-/

export async function withArtifactLock<T>(
  lockPath: string,
  action: () => T | Promise<T>,
  {
    retryDelay = () => sleep(retryMilliseconds),
    isProcessAlive = processIsAlive,
    pid = process.pid
  }: ArtifactLockOptions = {}
): Promise<T> {
  await mkdir(dirname(lockPath), { recursive: true })
  const staging = await mkdtemp(`${lockPath}.pending-`)
  const owner = `owner-${pid}-${randomUUID()}`
  try {
    await writeFile(join(staging, owner), String(pid), { flag: "wx" })
    await acquire(lockPath, staging, isProcessAlive, retryDelay)
    try {
      return await action()
    } finally {
      await ignoring(["ENOENT"], () => unlink(join(lockPath, owner)))
      await removeEmpty(lockPath)
    }
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

async function acquire(
  lockPath: string,
  staging: string,
  isProcessAlive: (pid: number) => boolean | Promise<boolean>,
  retryDelay: () => Promise<unknown>
): Promise<void> {
  for (;;) {
    if (await renamedInto(staging, lockPath)) return

    await cleanStale(lockPath, isProcessAlive)
    if (await exists(lockPath)) await retryDelay()
  }
}

async function renamedInto(staging: string, lockPath: string): Promise<boolean> {
  try {
    await rename(staging, lockPath)
    return true
  } catch (error) {
    if (renameConflicts.has(codeOf(error) ?? "")) return false
    throw error
  }
}

async function cleanStale(
  path: string,
  isProcessAlive: (pid: number) => boolean | Promise<boolean>
): Promise<void> {
  const info = await lstat(path).catch((error: unknown) =>
    codeOf(error) === "ENOENT" ? undefined : Promise.reject(error)
  )
  if (info === undefined) return
  if (!info.isDirectory()) return cleanStaleFile(path, isProcessAlive)

  const names = await readdir(path).catch((error: unknown) =>
    codeOf(error) === "ENOENT" ? undefined : Promise.reject(error)
  )
  if (names === undefined) return
  for (const name of names) {
    const owner = ownerName.exec(name)?.[1]
    if (owner === undefined) throw new Error(`Invalid artifact lock entry: ${join(path, name)}`)
    if (await isProcessAlive(Number(owner))) return
  }
  for (const name of names) await ignoring(["ENOENT"], () => unlink(join(path, name)))
  await removeEmpty(path)
}

async function cleanStaleFile(
  path: string,
  isProcessAlive: (pid: number) => boolean | Promise<boolean>
): Promise<void> {
  const owner = Number.parseInt(await readFile(path, "utf8").catch(() => ""), 10)
  if (Number.isInteger(owner) && (await isProcessAlive(owner))) return

  await ignoring(["ENOENT", "EISDIR", "EPERM"], () => unlink(path))
}

async function removeEmpty(path: string): Promise<void> {
  await ignoring(["ENOENT", "ENOTEMPTY", "EEXIST", "ENOTDIR"], () => rmdir(path))
}

async function exists(path: string): Promise<boolean> {
  try {
    await lstat(path)
    return true
  } catch (error) {
    if (codeOf(error) === "ENOENT") return false
    throw error
  }
}

async function ignoring(
  codes: ReadonlyArray<string>,
  operation: () => Promise<unknown>
): Promise<void> {
  try {
    await operation()
  } catch (error) {
    if (!codes.includes(codeOf(error) ?? "")) throw error
  }
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return codeOf(error) === "EPERM"
  }
}

function codeOf(error: unknown): string | undefined {
  return error instanceof Error && "code" in error && typeof error.code === "string"
    ? error.code
    : undefined
}
