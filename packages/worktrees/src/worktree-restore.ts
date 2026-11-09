import { existsSync } from "node:fs"

import {
  addWorktree,
  type GitOutputListener,
  GitError,
  isWorktreeBranchCollision,
  listCodevisorWorktreeBranchNames,
  releaseBranch,
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
  isTaken: (name: string) => boolean
): string | undefined => {
  if (!isTaken(originalName)) return originalName
  for (let suffix = 2; suffix <= 99; suffix += 1) {
    const candidate = `${originalName}-${String(suffix)}`
    if (!isTaken(candidate)) return candidate
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
  const { repoDir, worktreePathFor, parentSha, snapshotRef, env } = request
  const isTaken = await takenNamesFor(request)

  const hasSnapshot = await snapshotExists(repoDir, snapshotRef, env)
  let startPoint = parentSha
  if (!hasSnapshot) startPoint = (await worktreeStartPoint(repoDir, undefined, env)) ?? parentSha

  const name = await addRestoredWorktree(request, isTaken, startPoint)
  return {
    name,
    branch: restoredBranch(name),
    restoredFromSnapshot:
      hasSnapshot && (await applySnapshot(worktreePathFor(name), snapshotRef, parentSha, env))
  }
}

const restoredBranch = (name: string): string => `codevisor/${name}`

const takenNamesFor = async (request: RestoreRequest): Promise<(name: string) => boolean> => {
  const branchNames = await listCodevisorWorktreeBranchNames(request.repoDir, request.env).catch(
    /* v8 ignore next */
    () => [] as ReadonlyArray<string>
  )
  const taken = new Set([...request.takenNames, ...branchNames])
  return (name) => taken.has(name) || existsSync(request.worktreePathFor(name))
}

const addRestoredWorktree = async (
  request: RestoreRequest,
  isTaken: (name: string) => boolean,
  startPoint: string
): Promise<string> => {
  const collided = new Set<string>()
  for (;;) {
    const name = chooseRestoreName(
      request.originalName,
      (candidate) => collided.has(candidate) || isTaken(candidate)
    )
    if (name === undefined) {
      throw new GitError(
        "restore-worktree",
        `No available worktree name near ${request.originalName}`
      )
    }
    if (await addUnlessBranchCollides(request, name, startPoint)) return name
    collided.add(name)
  }
}

const addUnlessBranchCollides = async (
  request: RestoreRequest,
  name: string,
  startPoint: string
): Promise<boolean> => {
  const { repoDir, worktreePathFor, onOutput, env } = request
  const branch = restoredBranch(name)
  try {
    await addWorktree(repoDir, worktreePathFor(name), branch, onOutput, startPoint, env)
    return true
  } catch (cause) {
    if (isWorktreeBranchCollision(cause)) return false
    await releaseBranch(repoDir, branch, env)
    throw cause
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
