import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { lstat, mkdir, readdir, rename, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { promisify } from "node:util"

import { removeWorktree } from "./git.js"

const neverIndexMarker = ".metadata_never_index"

export interface TrashedWorktree {
  readonly purged: Promise<void>
}

const done: TrashedWorktree = { purged: Promise.resolve() }

const exists = (path: string): Promise<boolean> =>
  lstat(path).then(
    () => true,
    () => false
  )

const prepareTrashRoot = async (trashRoot: string): Promise<void> => {
  await mkdir(trashRoot, { recursive: true })
  await writeFile(join(trashRoot, neverIndexMarker), "", { flag: "a" })
}

export type TrashCommandRunner = (command: string, args: ReadonlyArray<string>) => Promise<void>

export interface TrashQueue {
  readonly enqueue: (path: string) => Promise<void>
}

export const makeTrashQueue = (
  run: TrashCommandRunner,
  log: (line: string) => void
): TrashQueue => {
  const pending = new Map<string, Promise<void>>()
  let tail: Promise<void> = Promise.resolve()
  return {
    enqueue: (path) => {
      const queued = pending.get(path)
      if (queued !== undefined) return queued
      const purged = tail.then(async () => {
        try {
          await run("/bin/rm", ["-rf", "--", path])
        } catch (cause) {
          log(`Couldn't delete trashed ${path}: ${String(cause)}`)
        } finally {
          pending.delete(path)
        }
      })
      pending.set(path, purged)
      tail = purged
      return purged
    }
  }
}

const execFileAsync = promisify(execFile)

export const worktreeTrashQueue: TrashQueue = makeTrashQueue(
  async (command, args) => {
    await execFileAsync(command, [...args])
  },
  (line) => console.error(line)
)

const purge = (path: string): Promise<void> => worktreeTrashQueue.enqueue(path)

export const trashWorktree = async (
  repoDir: string,
  worktreeDir: string,
  options: {
    readonly trashRoot: string
    readonly id: string
    readonly env?: NodeJS.ProcessEnv | undefined
  }
): Promise<TrashedWorktree> => {
  if (!(await exists(worktreeDir))) return done
  const target = join(options.trashRoot, `${options.id}-${randomUUID()}`)
  try {
    await prepareTrashRoot(options.trashRoot)
    await rename(worktreeDir, target)
  } catch {
    await removeWorktree(repoDir, worktreeDir, options.env, "utility")
    return done
  }
  return { purged: purge(target) }
}

export const trashDirectory = async (
  directory: string,
  options: { readonly trashRoot: string; readonly id: string }
): Promise<TrashedWorktree> => {
  if (!(await exists(directory))) return done
  const target = join(options.trashRoot, `${options.id}-${randomUUID()}`)
  try {
    await prepareTrashRoot(options.trashRoot)
    await rename(directory, target)
  } catch {
    return { purged: purge(directory) }
  }
  return { purged: purge(target) }
}

export const sweepWorktreeTrash = async (trashRoot: string): Promise<void> => {
  let entries: ReadonlyArray<string>
  try {
    entries = await readdir(trashRoot)
  } catch {
    return
  }
  await Promise.all(
    entries
      .filter((entry) => entry !== neverIndexMarker)
      .map((entry) => purge(join(trashRoot, entry)))
  )
}
