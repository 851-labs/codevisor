import { constants } from "node:fs"
import { copyFile, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { runGit } from "./git.js"

/// Scratch-index commands read a copy of the worktree's index from a scratch
/// path. An fsmonitor daemon answers for the real index, not the copy, and a
/// split index names a shared file beside the real one; both are turned off so
/// git reads the copy by itself and checks the files on disk.
export const scratchIndexConfig = ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false"]

/// Capturing the working state stats and hashes a whole checkout. Someone is
/// usually waiting on it (an unarchive, a review pane, a prompt), so it is
/// throttled rather than deferred. The buffer is raised because listings of a
/// large checkout pass 1MB.
export const heavyGit = { priority: "utility", maxBuffer: 256 * 1024 * 1024 } as const

const codevisorIdentityName = "Codevisor"
const codevisorIdentityEmail = "noreply@codevisor.app"

/// A scratch GIT_INDEX_FILE plus the environment every command against it
/// runs with.
export interface ScratchIndex {
  readonly indexFile: string
  readonly env: NodeJS.ProcessEnv
}

/// Runs `work` against a fresh, empty scratch index so the user's real index
/// is never touched: `git add -A` against the live index would stage
/// everything as a side effect, visible to the user if anything failed
/// partway (or even if nothing did).
///
/// A unique directory per call, NOT a name derived from the worktree: two
/// captures of the same checkout can run at once (a review refresh racing a
/// prompt's turn snapshot), and a shared GIT_INDEX_FILE would let them corrupt
/// each other's staging.
export const withScratchIndex = async <A>(
  env: NodeJS.ProcessEnv | undefined,
  work: (scratch: ScratchIndex) => Promise<A>
): Promise<A> => {
  const scratchDir = await mkdtemp(join(tmpdir(), "codevisor-index-"))
  const indexFile = join(scratchDir, "index")
  try {
    return await work({
      indexFile,
      env: {
        ...(env ?? process.env),
        GIT_INDEX_FILE: indexFile,
        // Commits built from a scratch index are machine-written, so they
        // carry their own identity rather than borrowing the user's. That
        // keeps authorship honest, and — the reason this is not merely
        // cosmetic — makes `commit-tree` work on a machine with no git
        // identity configured at all, where it would otherwise abort with
        // "Author identity unknown".
        GIT_AUTHOR_NAME: codevisorIdentityName,
        GIT_AUTHOR_EMAIL: codevisorIdentityEmail,
        GIT_COMMITTER_NAME: codevisorIdentityName,
        GIT_COMMITTER_EMAIL: codevisorIdentityEmail
      }
    })
  } finally {
    /* v8 ignore next -- scratch dir is ours and `force` already tolerates a
       missing path, so the rejection arm needs a failing unlink to reach. */
    await rm(scratchDir, { force: true, recursive: true }).catch(() => undefined)
  }
}

/// Copies the worktree's real index into the scratch index. A copy-on-write
/// clone where the filesystem supports it, so even a huge index costs almost
/// nothing to duplicate. Rejects when the worktree has no index yet.
export const copyRealIndex = async (
  dir: string,
  scratch: ScratchIndex,
  env?: NodeJS.ProcessEnv
): Promise<void> => {
  // `--git-path` answers relative to the working directory on gits older than
  // `--path-format`, so the result is resolved against it.
  const realIndex = await runGit("index-path", ["rev-parse", "--git-path", "index"], dir, env)
  await copyFile(resolve(dir, realIndex), scratch.indexFile, constants.COPYFILE_FICLONE)
}

/// Stages every non-ignored file in the checkout into the (already seeded)
/// scratch index and writes it out as a tree. Untracked files are included;
/// ignored files are not, except those the seed already tracks.
export const writeWorkingTree = async (dir: string, scratch: ScratchIndex): Promise<string> => {
  await runGit("add", [...scratchIndexConfig, "add", "-A"], dir, scratch.env, heavyGit)
  return runGit("write-tree", [...scratchIndexConfig, "write-tree"], dir, scratch.env, heavyGit)
}
