import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { lstat, mkdir, readdir, rename, rmdir, statfs, unlink, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { removeWorktree } from "./git.js"
import { type CommandPriority, withPriority } from "./low-priority.js"

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

export const LOW_DISK_FREE_BYTES = 20 * 1024 ** 3
export const LOW_DISK_FREE_RATIO = 0.1

export const purgePriority = (
  space: { readonly free: number; readonly total: number } | undefined
): CommandPriority =>
  space !== undefined &&
  (space.free < LOW_DISK_FREE_BYTES || space.free < space.total * LOW_DISK_FREE_RATIO)
    ? "utility"
    : "background"

export const diskSpace = async (
  path: string
): Promise<{ readonly free: number; readonly total: number } | undefined> => {
  try {
    const stats = await statfs(path)
    return { free: stats.bavail * stats.bsize, total: stats.blocks * stats.bsize }
  } catch {
    return undefined
  }
}

const purge = async (path: string): Promise<void> => {
  const priority = purgePriority(await diskSpace(path))
  return new Promise((resolve) => {
    const command = withPriority("/bin/rm", ["-rf", "--", path], priority)
    execFile(command.command, [...command.args], () => resolve())
  })
}

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

const ignore = (): void => undefined

export const moveTrashEntries = async (fromRoot: string, toRoot: string): Promise<void> => {
  let entries: ReadonlyArray<string>
  try {
    entries = (await readdir(fromRoot)).filter((entry) => entry !== neverIndexMarker)
    await prepareTrashRoot(toRoot)
  } catch {
    return
  }
  let moved = 0
  for (const entry of entries) {
    try {
      await rename(join(fromRoot, entry), join(toRoot, entry))
      moved += 1
    } catch {}
  }
  if (moved < entries.length) return
  await unlink(join(fromRoot, neverIndexMarker)).catch(ignore)
  await rmdir(fromRoot).catch(ignore)
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
