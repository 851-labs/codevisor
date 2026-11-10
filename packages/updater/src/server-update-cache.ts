import { readdir, realpath, rm, statfs } from "node:fs/promises"
import { join, relative, sep } from "node:path"

export interface ServerUpdateCacheFs {
  readonly list: (directory: string) => Promise<ReadonlyArray<string>>
  readonly remove: (path: string) => Promise<void>
  readonly resolve: (path: string) => Promise<string>
  readonly freeBytes: (path: string) => Promise<number>
}

export interface ServerUpdatePrune {
  readonly kept: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly failures: ReadonlyArray<ServerUpdatePruneFailure>
}

export interface ServerUpdatePruneFailure {
  readonly entry: string
  readonly message: string
}

export interface ServerUpdateCache {
  readonly directory: string
  readonly versionDirectory: (version: string) => string
  readonly prune: (keepVersions: ReadonlyArray<string>) => Promise<ServerUpdatePrune>
  readonly discard: (version: string) => Promise<ServerUpdatePrune>
  readonly ensureRoomFor: (archiveBytes: number | undefined) => Promise<void>
}

export interface ServerUpdateCacheOptions {
  readonly dataDir: string
  readonly runningEntrypoint: string | undefined
  readonly fs?: ServerUpdateCacheFs
}

export const SERVER_UPDATES_DIRECTORY = "server-updates"
export const ASSUMED_ARCHIVE_BYTES = 512 * 1024 * 1024
export const ARCHIVE_SPACE_FACTOR = 5
export const FREE_SPACE_RESERVE_BYTES = 1024 * 1024 * 1024

/* v8 ignore start */
export const defaultServerUpdateCacheFs: ServerUpdateCacheFs = {
  list: (directory) => readdir(directory),
  remove: (path) => rm(path, { recursive: true, force: true }),
  resolve: (path) => realpath(path),
  freeBytes: async (path) => {
    const stats = await statfs(path)
    return stats.bavail * stats.bsize
  }
}
/* v8 ignore stop */

export const serverUpdateCache = (options: ServerUpdateCacheOptions): ServerUpdateCache => {
  const fs = options.fs ?? defaultServerUpdateCacheFs
  const directory = join(options.dataDir, SERVER_UPDATES_DIRECTORY)
  const serialized = serialQueue()

  const removeUnless = (isKept: (entry: string) => boolean): Promise<ServerUpdatePrune> =>
    serialized(async () => {
      const entries = await listEntries(fs, directory)
      const running = await runningEntries(fs, directory, options.runningEntrypoint)
      const kept = entries.filter((entry) => running.includes(entry) || isKept(entry))
      const stale = entries.filter((entry) => !kept.includes(entry))
      return { kept, ...(await removeEntries(fs, directory, stale)) }
    })

  return {
    directory,
    versionDirectory: (version) => join(directory, version),
    prune: (keepVersions) => removeUnless((entry) => keepVersions.includes(entry)),
    discard: (version) => removeUnless((entry) => entry !== version),
    ensureRoomFor: (archiveBytes) => ensureRoom(fs, options.dataDir, archiveBytes)
  }
}

export const requiredFreeBytes = (archiveBytes: number | undefined): number =>
  (archiveBytes ?? ASSUMED_ARCHIVE_BYTES) * ARCHIVE_SPACE_FACTOR + FREE_SPACE_RESERVE_BYTES

export const explainDiskFull = (cause: unknown, directory: string): unknown => {
  if (!isDiskFull(cause)) return cause

  return new Error(
    `The disk is full, so the Codevisor server update couldn't be saved in ${directory}. ` +
      "Free up space, then try the update again.",
    { cause }
  )
}

const ensureRoom = async (
  fs: ServerUpdateCacheFs,
  dataDir: string,
  archiveBytes: number | undefined
): Promise<void> => {
  const required = requiredFreeBytes(archiveBytes)
  const available = await fs.freeBytes(dataDir)
  if (available >= required) return

  throw new Error(
    `Not enough free disk space to update the Codevisor server: it needs ${gigabytes(required)} ` +
      `free in ${dataDir}, but only ${gigabytes(available)} is available. ` +
      "Free up space, then try the update again."
  )
}

const listEntries = async (
  fs: ServerUpdateCacheFs,
  directory: string
): Promise<ReadonlyArray<string>> => {
  try {
    return (await fs.list(directory)).toSorted()
  } catch (cause) {
    if (errorCode(cause) === "ENOENT") return []
    throw cause
  }
}

const runningEntries = async (
  fs: ServerUpdateCacheFs,
  directory: string,
  entrypoint: string | undefined
): Promise<ReadonlyArray<string | undefined>> => {
  if (entrypoint === undefined || entrypoint.length === 0) return []

  const resolved = relative(await resolvedPath(fs, directory), await resolvedPath(fs, entrypoint))
  return [relative(directory, entrypoint), resolved].map(topLevelEntry)
}

const removeEntries = async (
  fs: ServerUpdateCacheFs,
  directory: string,
  entries: ReadonlyArray<string>
): Promise<Pick<ServerUpdatePrune, "removed" | "failures">> => {
  const removed: Array<string> = []
  const failures: Array<ServerUpdatePruneFailure> = []
  for (const entry of entries) {
    try {
      await fs.remove(join(directory, entry))
      removed.push(entry)
    } catch (cause) {
      failures.push({ entry, message: errorMessage(cause) })
    }
  }
  return { removed, failures }
}

const serialQueue = () => {
  let tail: Promise<unknown> = Promise.resolve()
  return <T>(task: () => Promise<T>): Promise<T> => {
    const run = tail.then(task)
    tail = run.catch(() => undefined)
    return run
  }
}

const resolvedPath = (fs: ServerUpdateCacheFs, path: string): Promise<string> =>
  fs.resolve(path).catch(() => path)

const topLevelEntry = (path: string): string | undefined => {
  const first = path.split(sep)[0]
  return first === "" || first === ".." ? undefined : first
}

const isDiskFull = (cause: unknown): boolean => errorCode(cause) === "ENOSPC"

const errorCode = (cause: unknown): unknown =>
  typeof cause === "object" && cause !== null && "code" in cause ? cause.code : undefined

const errorMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const gigabytes = (bytes: number): string => `${(bytes / 1024 ** 3).toFixed(1)} GB`
