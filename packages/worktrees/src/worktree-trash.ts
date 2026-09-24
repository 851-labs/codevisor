import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { lstat, mkdir, readdir, rename, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { removeWorktree } from "./git.js"
import { withPriority } from "./low-priority.js"

/// Removing a worktree used to mean `git worktree remove --force`, which
/// unlinks every file (often a six-figure `node_modules`) before returning.
/// Everything that waited on it -- the archive, the next archive, an unarchive
/// of the same workspace -- waited for all of that disk work.
///
/// Instead the directory is renamed into a trash folder on the same volume,
/// which is a single metadata operation, and the files are deleted afterwards
/// at background priority where nobody is waiting on them.

/// Spotlight skips any directory holding this file. Without it, macOS indexes
/// every trashed file it is told has moved, only to be told moments later that
/// it was deleted.
const neverIndexMarker = ".metadata_never_index"

export interface TrashedWorktree {
  /// Settles once the trashed files are deleted. Never rejects: files left
  /// behind are swept on the next boot.
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

/// Deletes a trashed directory at background priority.
const purge = (path: string): Promise<void> =>
  new Promise((resolve) => {
    const command = withPriority("/bin/rm", ["-rf", "--", path], "background")
    // A failure leaves the directory for the next boot's sweep.
    execFile(command.command, [...command.args], () => resolve())
  })

/// Moves a worktree's files out of the way so its path, and the git branch
/// checked out there, can be released immediately. The caller still owns
/// pruning git's registration of the old path.
///
/// A path that is already gone counts as removed. When the rename itself
/// cannot work (the trash is on another volume, or the directory is busy or
/// protected), this falls back to having git delete the files in place.
export const trashWorktree = async (
  repoDir: string,
  worktreeDir: string,
  options: {
    readonly trashRoot: string
    readonly id: string
    readonly env?: NodeJS.ProcessEnv | undefined
  }
): Promise<TrashedWorktree> => {
  // Checked first so an already-removed worktree never creates a trash folder.
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

/// Deletes whatever an earlier run left in the trash, for example when the
/// server stopped before a background delete finished.
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
