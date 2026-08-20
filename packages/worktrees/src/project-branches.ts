import type { ProjectGitBranch, ProjectWorktreeBase } from "@codevisor/api"

import { GitError, runGit } from "./git.js"

const remoteNames = async (
  repoDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> =>
  (await runGit("list-remotes", ["remote"], repoDir, env))
    .split("\n")
    .map((name) => name.trim())
    .filter((name) => name.length > 0)
    .toSorted((left, right) => right.length - left.length)

/// Refreshes and lists the remote-tracking branches a project can use as a
/// worktree base. Fetching is best-effort so the settings sheet remains useful
/// offline; cached refs are still returned when the network is unavailable.
export const listProjectGitBranches = async (
  repoDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<ProjectGitBranch>> => {
  await runGit(
    "fetch-branches",
    ["fetch", "--all", "--prune", "--no-tags", "--no-recurse-submodules"],
    repoDir,
    env
  ).catch(() => undefined)

  const remotes = await remoteNames(repoDir, env)
  const output = await runGit(
    "list-remote-branches",
    ["for-each-ref", "--format=%(refname)%00%(symref)", "refs/remotes/"],
    repoDir,
    env
  )
  const records = output
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => {
      const separator = line.indexOf("\0")
      return { ref: line.slice(0, separator), symbolicTarget: line.slice(separator + 1) }
    })
  const defaultRefs = new Set(
    records.map((record) => record.symbolicTarget).filter((ref) => ref.length > 0)
  )

  return records
    .filter((record) => record.symbolicTarget.length === 0)
    .flatMap((record): ReadonlyArray<ProjectGitBranch> => {
      const remote = remotes.find((candidate) =>
        record.ref.startsWith(`refs/remotes/${candidate}/`)
      )
      if (remote === undefined) return []
      const branch = record.ref.slice(`refs/remotes/${remote}/`.length)
      if (branch === "HEAD") return []
      return [{ remote, branch, isDefault: defaultRefs.has(record.ref) }]
    })
    .toSorted((left, right) => {
      if (left.isDefault !== right.isDefault) return left.isDefault ? -1 : 1
      return `${left.remote}/${left.branch}`.localeCompare(`${right.remote}/${right.branch}`)
    })
}

/// Refreshes and returns the ref new worktrees should be cut from. Fetching is
/// best-effort so worktree creation still works offline: a cached `origin/main`
/// is preferred when it exists, otherwise `git worktree add` falls back to HEAD.
export const worktreeStartPoint = async (
  repoDir: string,
  configuredBase?: ProjectWorktreeBase,
  env?: NodeJS.ProcessEnv
): Promise<string | undefined> => {
  if (configuredBase !== undefined) {
    const displayName = `${configuredBase.remote}/${configuredBase.branch}`
    const remotes = await remoteNames(repoDir, env)
    if (!remotes.includes(configuredBase.remote)) {
      throw new GitError(
        "worktree-start-point",
        `Configured worktree base ${displayName} is unavailable because remote ${configuredBase.remote} does not exist.`
      )
    }
    try {
      await runGit(
        "check-worktree-base",
        ["check-ref-format", `refs/heads/${configuredBase.branch}`],
        repoDir,
        env
      )
    } catch {
      throw new GitError(
        "worktree-start-point",
        `Configured worktree base ${displayName} is not a valid branch.`
      )
    }
    const remoteRef = `refs/remotes/${configuredBase.remote}/${configuredBase.branch}`
    await runGit(
      "fetch",
      [
        "fetch",
        "--no-tags",
        "--no-recurse-submodules",
        configuredBase.remote,
        `+refs/heads/${configuredBase.branch}:${remoteRef}`
      ],
      repoDir,
      env
    ).catch(() => undefined)
    try {
      await runGit("rev-parse", ["rev-parse", "--verify", "--quiet", remoteRef], repoDir, env)
      return remoteRef
    } catch {
      throw new GitError(
        "worktree-start-point",
        `Configured worktree base ${displayName} is unavailable. Choose another branch in Manage Project.`
      )
    }
  }

  await runGit(
    "fetch",
    [
      "fetch",
      "--no-tags",
      "--no-recurse-submodules",
      "origin",
      "+refs/heads/main:refs/remotes/origin/main"
    ],
    repoDir,
    env
  ).catch(() => undefined)

  try {
    await runGit(
      "rev-parse",
      ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"],
      repoDir,
      env
    )
    return "origin/main"
  } catch {
    return undefined
  }
}
