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

export const turnStartRef = "refs/worktree/codevisor/turn-start"

const assertWorkTree = async (dir: string): Promise<void> => {
  if (!(await isGitWorkTree(dir))) {
    throw new GitReviewError("not_git_repository", "This folder isn't a Git repository.")
  }
}

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

const worktreeTree = (dir: string, env: NodeJS.ProcessEnv | undefined): Promise<string> =>
  withScratchIndex(env, (scratch) => captureWorkingTree(dir, scratch, env))

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
      /* v8 ignore next */
      if (!(cause instanceof GitError && cause.message.includes("unmerged"))) throw cause
      throw new GitReviewError(
        "unmerged_index",
        "Resolve merge conflicts to review staged changes.",
        { cause }
      )
    }
  })

const headTree = async (dir: string, env: NodeJS.ProcessEnv | undefined): Promise<string> => {
  try {
    return await runGit("head-tree", ["rev-parse", "--verify", "--quiet", "HEAD^{tree}"], dir, env)
  } catch {
    return runGit("empty-tree", ["hash-object", "-t", "tree", "/dev/null"], dir, env)
  }
}

const defaultBase = async (
  dir: string,
  env: NodeJS.ProcessEnv | undefined
): Promise<string | null> => {
  for (const ref of branchDiffBaseRefs) {
    try {
      await runGit("base-ref", ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`], dir, env)
      return await runGit("base-name", ["rev-parse", "--abbrev-ref", ref], dir, env)
    } catch {}
  }
  return null
}

const branchBase = async (
  dir: string,
  requested: string | undefined,
  env: NodeJS.ProcessEnv | undefined
): Promise<{ readonly tree: string; readonly base: string }> => {
  let base: string | null
  if (requested === undefined || requested.length === 0) base = await defaultBase(dir, env)
  else base = requested
  if (base === null) {
    throw new GitReviewError(
      "unknown_base",
      "Codevisor couldn't find a default branch to compare against."
    )
  }
  let mergeBase: string | undefined
  if (!base.startsWith("-")) {
    mergeBase = await runGit(
      "merge-base",
      ["merge-base", "HEAD", `${base}^{commit}`],
      dir,
      env
    ).catch(() => undefined)
  }
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
    default: {
      const oldTree = await turnStartTree(dir, env)
      return { oldTree, newTree: await worktreeTree(dir, env) }
    }
  }
}

export const gitDiff = async (
  dir: string,
  mode: GitDiffMode,
  options: {
    readonly base?: string
    readonly env?: NodeJS.ProcessEnv
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

export const gitRefs = async (dir: string, env?: NodeJS.ProcessEnv): Promise<GitRefs> => {
  await assertWorkTree(dir)
  const currentBranch = await runGit(
    "current-branch",
    ["symbolic-ref", "--short", "--quiet", "HEAD"],
    dir,
    env
  ).catch(() => null)
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
      const fields = line.split("\0")
      if (fields[1] !== "") return []
      const ref = fields[0]!
      const remote = ref.startsWith("refs/remotes/")
      return [{ name: ref.slice(remote ? "refs/remotes/".length : "refs/heads/".length), remote }]
    })
  return { currentBranch, defaultBase: await defaultBase(dir, env), branches }
}

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
