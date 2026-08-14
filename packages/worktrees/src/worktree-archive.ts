import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  addWorktree,
  type GitOutputListener,
  GitError,
  isWorktreeBranchCollision,
  listCodevisorWorktreeBranchNames,
  runGit,
  worktreeStartPoint
} from "./git.js"

/// Archiving a chat used to delete its worktree outright, losing any work that
/// was not committed. Instead we capture the worktree's full state as a commit
/// object under a hidden ref and then remove the files. The ref pins the
/// objects against GC, costs a compressed delta rather than a working copy,
/// and makes restore lossless.
///
/// The ref is keyed by worktree id, never by name: archiving frees the
/// worktree name back into the (finite, ~500-entry) food pool immediately, so
/// names recycle and cannot identify a snapshot.
export const snapshotRefFor = (worktreeId: string): string =>
  `refs/codevisor/archived/${worktreeId}`

const snapshotIdentityName = "Codevisor"
const snapshotIdentityEmail = "noreply@codevisor.app"

export interface WorktreeSnapshot {
  /// The commit the worktree was sitting on. Restore checks out from here, so
  /// it is the piece that must survive even if the branch moves or is deleted.
  readonly parentSha: string
  readonly snapshotSha: string
  readonly snapshotRef: string
  /// Gitignored files that were NOT captured (see `collectIgnoredPaths`).
  readonly ignoredPaths: ReadonlyArray<string>
}

/// Ignored files are deliberately excluded from the snapshot: they are usually
/// build output and dependency trees that restore can regenerate, and writing
/// them into git objects would bake secrets (a `.env`) into the repository —
/// which becomes a real leak if these refs are ever pushed. Callers surface
/// this list so the user can rescue anything genuinely precious first.
///
/// Obvious regenerable junk is filtered out so the warning stays meaningful.
const regenerablePattern =
  /(^|\/)(node_modules|\.venv|venv|__pycache__|target|dist|build|out|\.next|\.turbo|\.gradle|\.pytest_cache|coverage|\.DS_Store)(\/|$)/

export const meaningfulIgnoredPaths = (paths: ReadonlyArray<string>): ReadonlyArray<string> =>
  paths.filter((path) => !regenerablePattern.test(path))

const collectIgnoredPaths = async (
  worktreeDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  try {
    const output = await runGit(
      "list-ignored",
      ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"],
      worktreeDir,
      env
    )
    return meaningfulIgnoredPaths(
      output
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line.length > 0)
    )
  } catch {
    // Advisory only — never fail an archive because the warning scan failed.
    /* v8 ignore next -- `git status` on a worktree we just read succeeds, so
       this only guards a mid-archive filesystem fault. */
    return []
  }
}

/// Captures staged, unstaged, and untracked (non-ignored) state as one commit.
///
/// A scratch index is used so the user's real index is never touched: `git add
/// -A` against the live index would stage everything as a side effect of
/// archiving, which would be visible if the archive later failed partway.
export const snapshotWorktree = async (
  repoDir: string,
  worktreeDir: string,
  worktreeId: string,
  env?: NodeJS.ProcessEnv
): Promise<WorktreeSnapshot> => {
  const parentSha = await runGit("rev-parse", ["rev-parse", "HEAD"], worktreeDir, env)
  // A unique directory per call, NOT a name derived from the worktree id and
  // commit: two archives can legitimately share both (the same chat archived
  // on two servers, or identical repos committed in the same second), and a
  // shared GIT_INDEX_FILE would let them corrupt each other's staging.
  const scratchDir = await mkdtemp(join(tmpdir(), "codevisor-archive-"))
  const indexFile = join(scratchDir, "index")
  const scratchEnv: NodeJS.ProcessEnv = {
    ...(env ?? process.env),
    GIT_INDEX_FILE: indexFile,
    // The snapshot is a machine-written commit, so it carries its own
    // identity rather than borrowing the user's. That keeps authorship
    // honest, and — the reason this is not merely cosmetic — makes
    // `commit-tree` work on a machine with no git identity configured at
    // all, where it would otherwise abort with "Author identity unknown"
    // and make archiving impossible.
    GIT_AUTHOR_NAME: snapshotIdentityName,
    GIT_AUTHOR_EMAIL: snapshotIdentityEmail,
    GIT_COMMITTER_NAME: snapshotIdentityName,
    GIT_COMMITTER_EMAIL: snapshotIdentityEmail
  }
  try {
    // Seed the scratch index from HEAD so `add -A` records deletions of
    // tracked files rather than treating the tree as empty.
    await runGit("read-tree", ["read-tree", parentSha], worktreeDir, scratchEnv)
    await runGit("add", ["add", "-A"], worktreeDir, scratchEnv)
    const tree = await runGit("write-tree", ["write-tree"], worktreeDir, scratchEnv)
    const snapshotSha = await runGit(
      "commit-tree",
      ["commit-tree", tree, "-p", parentSha, "-m", `codevisor archive ${worktreeId}`],
      worktreeDir,
      scratchEnv
    )
    const snapshotRef = snapshotRefFor(worktreeId)
    // update-ref runs against the repo, not the (about to be deleted) worktree.
    await runGit("update-ref", ["update-ref", snapshotRef, snapshotSha], repoDir, env)
    return {
      parentSha,
      snapshotSha,
      snapshotRef,
      ignoredPaths: await collectIgnoredPaths(worktreeDir, env)
    }
  } finally {
    /* v8 ignore next -- scratch dir is ours and `force` already tolerates a
       missing path, so the rejection arm needs a failing unlink to reach. */
    await rm(scratchDir, { force: true, recursive: true }).catch(() => undefined)
  }
}

/// Archives a worktree end to end: capture, delete the files, release the name.
///
/// The branch deletion is the subtle half. Worktree names are picked against
/// BOTH the database and the repo's `refs/heads/codevisor/` namespace (a name
/// whose branch still exists reads as taken, by design — other servers share
/// that namespace). So leaving the branch behind would keep the name occupied
/// forever and defeat the point of archiving. Dropping it is safe precisely
/// because the snapshot commit has the branch tip as its parent: the ref keeps
/// every commit reachable, and restore recreates the branch from `parentSha`.
export const archiveWorktreeFiles = async (
  repoDir: string,
  worktreeDir: string,
  worktreeId: string,
  branch: string,
  removeFiles: (repoDir: string, path: string, env?: NodeJS.ProcessEnv) => Promise<unknown>,
  env?: NodeJS.ProcessEnv
): Promise<WorktreeSnapshot> => {
  const snapshot = await snapshotWorktree(repoDir, worktreeDir, worktreeId, env)
  await removeFiles(repoDir, worktreeDir, env)
  await releaseBranch(repoDir, branch, env)
  return snapshot
}

/// Best-effort: a branch another worktree still has checked out cannot be
/// deleted, and that is fine — the snapshot is already durable, and the name
/// is genuinely still in use.
export const releaseBranch = async (
  repoDir: string,
  branch: string,
  env?: NodeJS.ProcessEnv
): Promise<boolean> => {
  try {
    await runGit("branch-delete", ["branch", "-D", branch], repoDir, env)
    return true
  } catch {
    return false
  }
}

export const deleteSnapshot = async (
  repoDir: string,
  worktreeId: string,
  env?: NodeJS.ProcessEnv
): Promise<void> => {
  try {
    await runGit("update-ref", ["update-ref", "-d", snapshotRefFor(worktreeId)], repoDir, env)
  } catch {
    // Already gone (hard delete after a manual prune) is success.
  }
}

export const snapshotExists = async (
  repoDir: string,
  snapshotRef: string,
  env?: NodeJS.ProcessEnv
): Promise<boolean> => {
  try {
    await runGit("rev-parse", ["rev-parse", "--verify", `${snapshotRef}^{commit}`], repoDir, env)
    return true
  } catch {
    return false
  }
}

/// Picks the name a restore should use. Prefers the original — the whole point
/// of freeing names is that most restores can take theirs back — and falls
/// back to a numeric suffix. `sushi-2` is chosen over an id fragment because
/// it reads as "the same sushi, restored" in a sidebar.
export const chooseRestoreName = (
  originalName: string,
  taken: ReadonlySet<string>
): string | undefined => {
  if (!taken.has(originalName)) return originalName
  for (let suffix = 2; suffix <= 99; suffix += 1) {
    const candidate = `${originalName}-${String(suffix)}`
    if (!taken.has(candidate)) return candidate
  }
  return undefined
}

export interface RestoreRequest {
  readonly repoDir: string
  /// Where a worktree of a given name belongs. Takes the name rather than a
  /// fixed path because the restore may have to settle for a suffixed name,
  /// and the directory has to follow it — the original path is exactly the
  /// one that is likely occupied.
  readonly worktreePathFor: (name: string) => string
  readonly originalName: string
  readonly parentSha: string
  readonly snapshotRef: string
  /// Worktree names already in use for this project on this server. The caller
  /// owns this because only it can see the database.
  readonly takenNames: ReadonlySet<string>
  readonly onOutput?: GitOutputListener
  readonly env?: NodeJS.ProcessEnv
}

export interface RestoreResult {
  readonly name: string
  readonly branch: string
  /// False when the snapshot could not be applied and the worktree was
  /// recreated empty from the default branch. Callers surface this so the user
  /// is never silently handed a worktree missing their work.
  readonly restoredFromSnapshot: boolean
}

/// Recreates an archived worktree's files. Restores to the snapshot when it is
/// still reachable, and degrades to a fresh checkout otherwise (the repository
/// was re-cloned, pruned, or the ref was deleted by hand) rather than failing
/// the unarchive outright — the chat and its transcript are the primary thing
/// being restored; the files are best-effort.
export const restoreWorktree = async (request: RestoreRequest): Promise<RestoreResult> => {
  const { repoDir, worktreePathFor, originalName, parentSha, snapshotRef, env } = request

  // Branch names live in a namespace shared by every server touching this
  // repo, so a name free in our database can still be taken as a ref.
  const branchNames = await listCodevisorWorktreeBranchNames(repoDir).catch(
    /* v8 ignore next -- a for-each-ref over our own namespace fails only if
       the repo itself is unreadable, which the restore reports moments later. */
    () => [] as ReadonlyArray<string>
  )
  const taken = new Set([...request.takenNames, ...branchNames])
  const name = chooseRestoreName(originalName, taken)
  if (name === undefined) {
    throw new GitError("restore-worktree", `No available worktree name near ${originalName}`)
  }
  const branch = `codevisor/${name}`
  const path = worktreePathFor(name)

  const hasSnapshot = await snapshotExists(repoDir, snapshotRef, env)
  // Without the snapshot, parentSha may also be unreachable, so fall back to
  // whatever the repo considers a sane starting point.
  const startPoint = hasSnapshot ? parentSha : ((await worktreeStartPoint(repoDir)) ?? parentSha)

  try {
    await addWorktree(repoDir, path, branch, request.onOutput, startPoint, env)
    /* v8 ignore start -- pure race guard: reaching it needs another process to
       claim the branch between our ref scan and this add, which a single-
       process test cannot stage without stubbing git itself. */
  } catch (cause) {
    // Another server can claim the branch between our scan and the add. One
    // retry under a suffixed name is enough; a second collision is a real
    // failure worth surfacing.
    if (!isWorktreeBranchCollision(cause)) throw cause
    const retryName = chooseRestoreName(originalName, new Set([...taken, name]))
    if (retryName === undefined) throw cause
    const retryPath = worktreePathFor(retryName)
    await addWorktree(
      repoDir,
      retryPath,
      `codevisor/${retryName}`,
      request.onOutput,
      startPoint,
      env
    )
    return {
      name: retryName,
      branch: `codevisor/${retryName}`,
      restoredFromSnapshot:
        hasSnapshot && (await applySnapshot(retryPath, snapshotRef, parentSha, env))
    }
  }
  /* v8 ignore stop */

  return {
    name,
    branch,
    restoredFromSnapshot: hasSnapshot && (await applySnapshot(path, snapshotRef, parentSha, env))
  }
}

/// Materializes the snapshot's contents on top of a worktree already checked
/// out at `parentSha`.
///
/// Two steps, because the goal is to reproduce the *working state*, not to
/// land the snapshot as a commit: `read-tree -u` writes the snapshot's files
/// (adding, modifying, and deleting to match), then resetting the index back
/// to the parent re-marks those differences as uncommitted. The user gets
/// their worktree exactly as they left it — dirty files still dirty, untracked
/// files still untracked — rather than a surprise commit they never made.
const applySnapshot = async (
  worktreeDir: string,
  snapshotRef: string,
  parentSha: string,
  env?: NodeJS.ProcessEnv
): Promise<boolean> => {
  try {
    await runGit(
      "read-tree",
      ["read-tree", "-u", "--reset", `${snapshotRef}^{tree}`],
      worktreeDir,
      env
    )
    await runGit("reset-mixed", ["reset", "--mixed", parentSha], worktreeDir, env)
    return true
  } catch {
    /* v8 ignore next -- the caller checks the ref exists first, so failing
       here needs the objects to vanish mid-restore. */
    return false
  }
}
