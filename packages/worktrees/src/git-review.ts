import type { GitDiff, GitDiffMode, GitRefBranch, GitRefs } from "@codevisor/api"

import { diffFiles } from "./git-diff-files.js"
import { branchDiffBaseRefs, GitError, isGitWorkTree, runGit } from "./git.js"
import {
  copyRealIndex,
  heavyGit,
  type ScratchIndex,
  scratchIndexConfig,
  withScratchIndex,
  writeWorkingTree
} from "./working-state.js"

export type GitReviewFailureCode =
  | "not_git_repository"
  | "unmerged_index"
  | "unknown_base"
  | "no_turn_snapshot"

/// A review that cannot be produced for a reason the user can act on. The
/// server maps each code onto an HTTP status; anything else is a real fault.
export class GitReviewError extends Error {
  constructor(
    readonly code: GitReviewFailureCode,
    message: string,
    options?: ErrorOptions
  ) {
    super(message, options)
    this.name = "GitReviewError"
  }
}

/// Where the working tree is recorded when an agent turn starts, so "last
/// turn" can show exactly what the turn changed. `refs/worktree/` is private
/// to each checkout, so linked worktrees of one repository never overwrite
/// each other's snapshot.
export const turnStartRef = "refs/worktree/codevisor/turn-start"

const assertWorkTree = async (dir: string): Promise<void> => {
  if (!(await isGitWorkTree(dir))) {
    throw new GitReviewError("not_git_repository", "This folder isn't a Git repository.")
  }
}

/// Starts from the real index so paths the user force-added stay tracked and
/// unchanged files keep their stat data (only edited files get re-hashed). A
/// repository with nothing staged yet has no index file; an empty scratch
/// index is the same thing.
const seedFromRealIndex = (
  dir: string,
  scratch: ScratchIndex,
  env: NodeJS.ProcessEnv | undefined
): Promise<void> => copyRealIndex(dir, scratch, env).catch(() => undefined)

const captureWorkingTree = async (
  dir: string,
  scratch: ScratchIndex,
  env: NodeJS.ProcessEnv | undefined
): Promise<string> => {
  await seedFromRealIndex(dir, scratch, env)
  return writeWorkingTree(dir, scratch)
}

/// The working tree as git would commit it after `git add -A`: tracked edits
/// and deletions plus untracked, non-ignored files. Built in a scratch index,
/// so the user's staging is untouched.
const worktreeTree = (dir: string, env: NodeJS.ProcessEnv | undefined): Promise<string> =>
  withScratchIndex(env, (scratch) => captureWorkingTree(dir, scratch, env))

/// The staged tree. `write-tree` runs on a copy because it caches trees back
/// into the index it reads, and the real one is the user's.
const indexTree = (dir: string, env: NodeJS.ProcessEnv | undefined): Promise<string> =>
  withScratchIndex(env, async (scratch) => {
    await seedFromRealIndex(dir, scratch, env)
    try {
      return await runGit(
        "write-tree",
        [...scratchIndexConfig, "write-tree"],
        dir,
        scratch.env,
        heavyGit
      )
    } catch (cause) {
      /* v8 ignore next -- an index git can read but not write out as a tree
         is otherwise only a damaged object store. */
      if (!(cause instanceof GitError && cause.message.includes("unmerged"))) throw cause
      throw new GitReviewError(
        "unmerged_index",
        "Resolve merge conflicts to review staged changes.",
        { cause }
      )
    }
  })

/// HEAD's tree, or git's empty tree before the first commit so a new
/// repository reviews as "everything added".
const headTree = async (dir: string, env: NodeJS.ProcessEnv | undefined): Promise<string> => {
  try {
    return await runGit("head-tree", ["rev-parse", "--verify", "--quiet", "HEAD^{tree}"], dir, env)
  } catch {
    return runGit("empty-tree", ["hash-object", "-t", "tree", "/dev/null"], dir, env)
  }
}

/// The conventional default branch that exists here, by its short name. A
/// symbolic `origin/HEAD` reports the branch it points at (`origin/main`),
/// which is what a base picker should show.
const defaultBase = async (
  dir: string,
  env: NodeJS.ProcessEnv | undefined
): Promise<string | null> => {
  for (const ref of branchDiffBaseRefs) {
    try {
      await runGit("base-ref", ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`], dir, env)
      return await runGit("base-name", ["rev-parse", "--abbrev-ref", ref], dir, env)
    } catch {
      // Try the next conventional default-branch ref.
    }
  }
  return null
}

const branchBase = async (
  dir: string,
  requested: string | undefined,
  env: NodeJS.ProcessEnv | undefined
): Promise<{ readonly tree: string; readonly base: string }> => {
  const base =
    requested === undefined || requested.length === 0 ? await defaultBase(dir, env) : requested
  if (base === null) {
    throw new GitReviewError(
      "unknown_base",
      "Codevisor couldn't find a default branch to compare against."
    )
  }
  // A leading dash would reach git as an option, not a ref.
  const mergeBase = base.startsWith("-")
    ? undefined
    : await runGit("merge-base", ["merge-base", "HEAD", `${base}^{commit}`], dir, env).catch(
        () => undefined
      )
  if (mergeBase === undefined) {
    throw new GitReviewError(
      "unknown_base",
      `Codevisor couldn't find the branch ${base} in this repository.`
    )
  }
  return { tree: mergeBase, base }
}

const turnStartTree = async (dir: string, env: NodeJS.ProcessEnv | undefined): Promise<string> => {
  try {
    return await runGit(
      "turn-start",
      ["rev-parse", "--verify", "--quiet", `${turnStartRef}^{commit}`],
      dir,
      env
    )
  } catch (cause) {
    throw new GitReviewError("no_turn_snapshot", "No agent turn has started in this folder yet.", {
      cause
    })
  }
}

interface ComparedTrees {
  readonly oldTree: string
  readonly newTree: string
  readonly base?: string
}

/// The old side is resolved first: it is where a review fails for a reason
/// the user can fix, and the working-tree capture is the expensive half.
const comparedTrees = async (
  dir: string,
  mode: GitDiffMode,
  requestedBase: string | undefined,
  env: NodeJS.ProcessEnv | undefined
): Promise<ComparedTrees> => {
  switch (mode) {
    case "uncommitted": {
      const oldTree = await headTree(dir, env)
      return { oldTree, newTree: await worktreeTree(dir, env) }
    }
    case "unstaged": {
      const oldTree = await indexTree(dir, env)
      return { oldTree, newTree: await worktreeTree(dir, env) }
    }
    case "staged": {
      const oldTree = await headTree(dir, env)
      return { oldTree, newTree: await indexTree(dir, env) }
    }
    case "branch": {
      const { tree, base } = await branchBase(dir, requestedBase, env)
      return { oldTree: tree, newTree: await worktreeTree(dir, env), base }
    }
    case "lastTurn": {
      const oldTree = await turnStartTree(dir, env)
      return { oldTree, newTree: await worktreeTree(dir, env) }
    }
  }
}

/// Compares two trees of the repository containing `dir` (see `GitDiffMode`).
/// Never modifies the user's index or refs.
export const gitDiff = async (
  dir: string,
  mode: GitDiffMode,
  options: {
    readonly base?: string
    readonly env?: NodeJS.ProcessEnv
    /// The `revision` of a diff the caller already has. When the compared
    /// trees still match it, blob reading is skipped and no files are sent:
    /// the Review pane polls, and an unchanged folder must stay cheap.
    readonly knownRevision?: string
  } = {}
): Promise<GitDiff> => {
  const { env } = options
  await assertWorkTree(dir)
  const repositoryRoot = await runGit("toplevel", ["rev-parse", "--show-toplevel"], dir, env)
  const { oldTree, newTree, base } = await comparedTrees(dir, mode, options.base, env)
  const revision = `${oldTree}..${newTree}`
  const header = { mode, repositoryRoot, ...(base === undefined ? {} : { base }), revision }
  if (revision === options.knownRevision) {
    return { ...header, files: [], truncated: false, unchanged: true }
  }
  const { files, truncated } = await diffFiles(dir, oldTree, newTree, env)
  return { ...header, files, truncated }
}

/// Branches a review can compare against, from local refs only: a picker must
/// open instantly and offline, so nothing is fetched.
export const gitRefs = async (dir: string, env?: NodeJS.ProcessEnv): Promise<GitRefs> => {
  await assertWorkTree(dir)
  const currentBranch = await runGit(
    "current-branch",
    ["symbolic-ref", "--short", "--quiet", "HEAD"],
    dir,
    env
  ).catch(() => null)
  // for-each-ref sorts by full name, which puts refs/heads before
  // refs/remotes and each group in order.
  const output = await runGit(
    "list-refs",
    ["for-each-ref", "--format=%(refname)%00%(symref)", "refs/heads/", "refs/remotes/"],
    dir,
    env
  )
  const branches = output
    .split("\n")
    .filter((line) => line.length > 0)
    .flatMap((line): ReadonlyArray<GitRefBranch> => {
      const [ref, symbolicTarget] = line.split("\0") as [string, string]
      // `origin/HEAD` names another branch rather than being one.
      if (symbolicTarget.length > 0) return []
      const remote = ref.startsWith("refs/remotes/")
      return [{ name: ref.slice(remote ? "refs/remotes/".length : "refs/heads/".length), remote }]
    })
  return { currentBranch, defaultBase: await defaultBase(dir, env), branches }
}

/// Records the working tree as the start of an agent turn for `lastTurn`
/// reviews. A no-op (false) outside a git work tree. The commit's parent is
/// HEAD when there is one, which keeps its objects cheap deltas and reachable.
///
/// The ref is written only if `signal` has not aborted by then: a caller that
/// gave up waiting has already let the agent start editing, and a snapshot
/// finishing late would capture some of the turn's own changes.
export const recordTurnStartSnapshot = async (
  dir: string,
  options: { readonly env?: NodeJS.ProcessEnv; readonly signal?: AbortSignal } = {}
): Promise<boolean> => {
  const { env, signal } = options
  if (!(await isGitWorkTree(dir))) return false
  return withScratchIndex(env, async (scratch) => {
    const tree = await captureWorkingTree(dir, scratch, env)
    const head = await runGit(
      "rev-parse",
      ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
      dir,
      env
    ).catch(() => undefined)
    const commit = await runGit(
      "commit-tree",
      [
        "commit-tree",
        tree,
        ...(head === undefined ? [] : ["-p", head]),
        "-m",
        "codevisor turn start"
      ],
      dir,
      scratch.env,
      heavyGit
    )
    if (signal?.aborted === true) return false
    await runGit("update-ref", ["update-ref", turnStartRef, commit], dir, env)
    return true
  })
}
