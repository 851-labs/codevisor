import { runGit } from "./git.js"
import {
  copyRealIndex,
  heavyGit as heavy,
  type ScratchIndex,
  scratchIndexConfig as snapshotConfig,
  withScratchIndex,
  writeWorkingTree
} from "./working-state.js"
import { type TrashedWorktree, trashWorktree } from "./worktree-trash.js"

export {
  chooseRestoreName,
  type RestoreRequest,
  type RestoreResult,
  restoreWorktree,
  snapshotExists
} from "./worktree-restore.js"

export const snapshotRefFor = (worktreeId: string): string =>
  `refs/codevisor/archived/${worktreeId}`

export interface WorktreeSnapshot {
  readonly parentSha: string
  readonly snapshotSha: string
  readonly snapshotRef: string
  readonly ignoredPaths: ReadonlyArray<string>
}

const regenerablePattern =
  /(^|\/)(node_modules|\.venv|venv|__pycache__|target|dist|build|out|tmp|\.next|\.turbo|\.gradle|\.pytest_cache|coverage|\.DS_Store)(\/|$)/

export const meaningfulIgnoredPaths = (paths: ReadonlyArray<string>): ReadonlyArray<string> =>
  paths.filter((path) => !regenerablePattern.test(path))

const collectIgnoredPaths = async (
  worktreeDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  try {
    const output = await runGit(
      "list-ignored",
      [...snapshotConfig, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory"],
      worktreeDir,
      env,
      heavy
    )
    return meaningfulIgnoredPaths(
      output
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line.length > 0)
    )
  } catch {
    /* v8 ignore next */
    return []
  }
}

const seedScratchIndex = async (
  worktreeDir: string,
  parentSha: string,
  scratch: ScratchIndex,
  env: NodeJS.ProcessEnv | undefined
): Promise<void> => {
  try {
    await copyRealIndex(worktreeDir, scratch, env)
    await runGit(
      "read-tree",
      [...snapshotConfig, "read-tree", "-m", parentSha],
      worktreeDir,
      scratch.env,
      heavy
    )
    const entries = await runGit(
      "ls-files",
      [...snapshotConfig, "ls-files", "-v"],
      worktreeDir,
      scratch.env,
      heavy
    )
    if (!/^[a-z]/m.test(entries)) return
  } catch {}
  await runGit(
    "read-tree",
    [...snapshotConfig, "read-tree", parentSha],
    worktreeDir,
    scratch.env,
    heavy
  )
}

export const snapshotWorktree = async (
  repoDir: string,
  worktreeDir: string,
  worktreeId: string,
  env?: NodeJS.ProcessEnv
): Promise<WorktreeSnapshot> => {
  const parentSha = await runGit("rev-parse", ["rev-parse", "HEAD"], worktreeDir, env)
  return withScratchIndex(env, async (scratch) => {
    await seedScratchIndex(worktreeDir, parentSha, scratch, env)
    const tree = await writeWorkingTree(worktreeDir, scratch)
    const snapshotSha = await runGit(
      "commit-tree",
      ["commit-tree", tree, "-p", parentSha, "-m", `codevisor archive ${worktreeId}`],
      worktreeDir,
      scratch.env,
      heavy
    )
    const snapshotRef = snapshotRefFor(worktreeId)
    await runGit("update-ref", ["update-ref", snapshotRef, snapshotSha], repoDir, env, heavy)
    return {
      parentSha,
      snapshotSha,
      snapshotRef,
      ignoredPaths: await collectIgnoredPaths(worktreeDir, env)
    }
  })
}

export const removeArchivedWorktreeFiles = async (
  repoDir: string,
  worktreeDir: string,
  branch: string,
  options: {
    readonly trashRoot: string
    readonly worktreeId: string
    readonly env?: NodeJS.ProcessEnv
  }
): Promise<TrashedWorktree> => {
  const { env } = options
  const trashed = await trashWorktree(repoDir, worktreeDir, {
    trashRoot: options.trashRoot,
    id: options.worktreeId,
    env
  })
  await pruneWorktreeRegistrations(repoDir, env)
  await releaseBranch(repoDir, branch, env)
  return trashed
}

export const listSnapshotRefWorktreeIds = async (
  repoDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  try {
    const output = await runGit(
      "list-archive-refs",
      ["for-each-ref", "--format=%(refname:strip=3)", "refs/codevisor/archived/"],
      repoDir,
      env
    )
    return output
      .split("\n")
      .map((id) => id.trim())
      .filter((id) => id.length > 0)
  } catch {
    return []
  }
}

export const pruneWorktreeRegistrations = async (
  repoDir: string,
  env?: NodeJS.ProcessEnv
): Promise<void> => {
  try {
    await runGit("worktree-prune", ["worktree", "prune"], repoDir, env, { priority: "utility" })
  } catch {}
}

export const releaseBranch = async (
  repoDir: string,
  branch: string,
  env?: NodeJS.ProcessEnv
): Promise<boolean> => {
  try {
    await runGit("branch-delete", ["branch", "-D", branch], repoDir, env, { priority: "utility" })
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
  } catch {}
}
