import {
  addWorktree,
  type GitOutputListener,
  GitError,
  isWorktreeBranchCollision,
  listCodevisorWorktreeBranchNames,
  runGit
} from "./git.js"
import { worktreeStartPoint } from "./project-branches.js"
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
  readonly worktreePathFor: (name: string) => string
  readonly originalName: string
  readonly parentSha: string
  readonly snapshotRef: string
  readonly takenNames: ReadonlySet<string>
  readonly onOutput?: GitOutputListener
  readonly env?: NodeJS.ProcessEnv
}

export interface RestoreResult {
  readonly name: string
  readonly branch: string
  readonly restoredFromSnapshot: boolean
}

export const restoreWorktree = async (request: RestoreRequest): Promise<RestoreResult> => {
  const { repoDir, worktreePathFor, originalName, parentSha, snapshotRef, env } = request

  const branchNames = await listCodevisorWorktreeBranchNames(repoDir, env).catch(
    /* v8 ignore next */
    () => [] as ReadonlyArray<string>
  )
  const taken = new Set([...request.takenNames, ...branchNames])
  let name = chooseRestoreName(originalName, taken)
  if (name === undefined) {
    throw new GitError("restore-worktree", `No available worktree name near ${originalName}`)
  }
  let branch = `codevisor/${name}`
  let path = worktreePathFor(name)

  const hasSnapshot = await snapshotExists(repoDir, snapshotRef, env)
  const startPoint = hasSnapshot
    ? parentSha
    : ((await worktreeStartPoint(repoDir, undefined, env)) ?? parentSha)

  try {
    await addWorktree(repoDir, path, branch, request.onOutput, startPoint, env)
    /* v8 ignore start */
  } catch (cause) {
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
    name = retryName
    branch = `codevisor/${retryName}`
    path = retryPath
  }
  /* v8 ignore stop */

  return {
    name,
    branch,
    restoredFromSnapshot: hasSnapshot && (await applySnapshot(path, snapshotRef, parentSha, env))
  }
}

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
    /* v8 ignore next */
    return false
  }
}
