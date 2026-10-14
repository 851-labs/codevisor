import { execFile, spawn } from "node:child_process"
import { realpathSync } from "node:fs"
import { readFile } from "node:fs/promises"
import { join, resolve } from "node:path"

import type { BranchDiffTotals } from "@codevisor/api"

import { GitCommandOutput, type GitOutputListener } from "./git-output.js"
import { type CommandPriority, withPriority } from "./low-priority.js"

export {
  sanitizeGitOutputLine,
  type GitOutputListener,
  type GitOutputStream
} from "./git-output.js"

export class GitError extends Error {
  constructor(
    readonly operation: string,
    message: string
  ) {
    super(message)
    this.name = "GitError"
  }
}

export interface GitRunOptions {
  readonly priority?: CommandPriority | undefined
  readonly maxBuffer?: number
}

const git = (
  operation: string,
  args: ReadonlyArray<string>,
  cwd: string,
  env?: NodeJS.ProcessEnv,
  options: GitRunOptions = {}
): Promise<string> =>
  new Promise((resolve, reject) => {
    const command = withPriority("git", args, options.priority)
    execFile(
      command.command,
      command.args,
      { cwd, maxBuffer: options.maxBuffer ?? 1024 * 1024, ...(env === undefined ? {} : { env }) },
      (error, stdout, stderr) => {
        if (error !== null) {
          reject(new GitError(operation, stderr.trim().length > 0 ? stderr.trim() : error.message))
          return
        }
        resolve(stdout.trim())
      }
    )
  })

const gitRaw = (
  operation: string,
  args: ReadonlyArray<string>,
  cwd: string,
  env?: NodeJS.ProcessEnv
): Promise<string> =>
  new Promise((resolve, reject) => {
    execFile(
      "git",
      args,
      { cwd, ...(env === undefined ? {} : { env }) },
      (error, stdout, stderr) => {
        if (error !== null) {
          reject(new GitError(operation, stderr.trim().length > 0 ? stderr.trim() : error.message))
          return
        }
        resolve(stdout)
      }
    )
  })

export const runGit = (
  operation: string,
  args: ReadonlyArray<string>,
  cwd: string,
  env?: NodeJS.ProcessEnv,
  options?: GitRunOptions
): Promise<string> => git(operation, args, cwd, env, options)

export const isGitWorkTree = async (dir: string, env?: NodeJS.ProcessEnv): Promise<boolean> => {
  try {
    return (await git("rev-parse", ["rev-parse", "--is-inside-work-tree"], dir, env)) === "true"
  } catch {
    return false
  }
}

export const gitRemoteUrl = async (
  dir: string,
  env?: NodeJS.ProcessEnv
): Promise<string | undefined> => {
  const remoteUrl = (remote: string): Promise<string> =>
    git("remote-url", ["remote", "get-url", remote], dir, env)
  try {
    return await remoteUrl("origin")
  } catch {}
  try {
    const first = (await git("list-remotes", ["remote"], dir, env))
      .split("\n")
      .map((name) => name.trim())
      .find((name) => name.length > 0)
    return first === undefined ? undefined : await remoteUrl(first)
  } catch {
    return undefined
  }
}

export const listCodevisorWorktreeBranchNames = async (
  repoDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  const output = await gitRaw(
    "list-codevisor-branches",
    ["for-each-ref", "--format=%(refname:strip=3)", "refs/heads/codevisor/"],
    repoDir,
    env
  )
  return output
    .split("\n")
    .map((name) => name.trim())
    .filter((name) => name.length > 0)
}

export const isWorktreeBranchCollision = (cause: unknown): boolean =>
  cause instanceof GitError && /branch named ['"].+['"] already exists/i.test(cause.message)

export const branchDiffBaseRefs = ["origin/HEAD", "origin/main", "origin/master", "main", "master"]

export const parseGitNumstat = (numstat: string): BranchDiffTotals => {
  const totals = { added: 0, removed: 0 }
  for (const line of numstat.split("\n")) {
    const fields = line.split("\t")
    if (fields.length < 2) continue
    totals.added += Number.parseInt(fields[0]!, 10) || 0
    totals.removed += Number.parseInt(fields[1]!, 10) || 0
  }
  return totals
}

async function untrackedLineCount(path: string): Promise<number> {
  try {
    const data = await readFile(path)
    if (data.length === 0 || data.length > 4_000_000) return 0
    if (data.subarray(0, 8192).includes(0)) return 0
    let newlines = 0
    for (const byte of data) {
      if (byte === 10) newlines += 1
    }
    return data.at(-1) === 10 ? newlines : newlines + 1
  } catch {
    return 0
  }
}

export const gitBranchDiffTotals = async (
  directory: string
): Promise<BranchDiffTotals | undefined> => {
  if (!(await isGitWorkTree(directory))) return undefined
  try {
    let base = "HEAD"
    for (const ref of branchDiffBaseRefs) {
      try {
        const candidate = await git("merge-base", ["merge-base", "HEAD", ref], directory)
        if (candidate !== "") {
          base = candidate
          break
        }
      } catch {}
    }
    const totals = parseGitNumstat(await git("branch-diff", ["diff", "--numstat", base], directory))
    const untracked = await gitRaw(
      "untracked-files",
      ["ls-files", "--others", "--exclude-standard", "-z"],
      directory
    )
    let untrackedAdditions = 0
    for (const path of untracked.split("\0")) {
      if (path !== "") untrackedAdditions += await untrackedLineCount(join(directory, path))
    }
    return {
      added: totals.added + untrackedAdditions,
      removed: totals.removed
    }
  } catch {
    return undefined
  }
}

export const addWorktree = (
  repoDir: string,
  path: string,
  branch: string,
  onOutput?: GitOutputListener,
  startPoint?: string,
  env?: NodeJS.ProcessEnv
): Promise<void> =>
  new Promise((resolve, reject) => {
    const args = ["worktree", "add", path, "-b", branch]
    if (startPoint !== undefined) {
      args.push(startPoint)
    }
    const child = spawn("git", args, {
      cwd: repoDir,
      ...(env === undefined ? {} : { env })
    })
    const output = new GitCommandOutput(child, onOutput)
    const settle = (failure: GitError | undefined): void => {
      output.flush()
      if (failure === undefined) {
        resolve()
      } else {
        reject(failure)
      }
    }
    child.once("error", (cause) => {
      settle(new GitError("worktree", cause.message))
    })
    child.once("close", (code) => {
      const stderrText = output.stderrLines.join("\n").trim()
      settle(
        code === 0
          ? undefined
          : new GitError(
              "worktree",
              stderrText.length > 0
                ? stderrText
                : `git worktree add exited with code ${String(code)}`
            )
      )
    })
  })

export type CloneFailureCode =
  | "auth_failed"
  | "repo_not_found"
  | "network"
  | "disk_full"
  | "invalid_url"

export const classifyCloneFailure = (stderrText: string): CloneFailureCode | undefined => {
  const text = stderrText.toLowerCase()
  if (
    text.includes("authentication failed") ||
    text.includes("could not read username") ||
    text.includes("could not read password") ||
    text.includes("permission denied (publickey") ||
    text.includes("host key verification failed") ||
    text.includes("support for password authentication was removed")
  ) {
    return "auth_failed"
  }
  if (text.includes("repository") && text.includes("not found")) {
    return "repo_not_found"
  }
  if (
    text.includes("could not resolve host") ||
    text.includes("unable to access") ||
    text.includes("connection timed out") ||
    text.includes("connection refused")
  ) {
    return "network"
  }
  if (text.includes("no space left on device")) {
    return "disk_full"
  }
  if (
    text.includes("does not appear to be a git repository") ||
    text.includes("is not a valid repository name")
  ) {
    return "invalid_url"
  }
  return undefined
}

export class CloneError extends GitError {
  constructor(
    message: string,
    readonly code: CloneFailureCode | undefined
  ) {
    super("clone", message)
    this.name = "CloneError"
  }
}

export const cloneRepository = (
  url: string,
  destination: string,
  onOutput?: GitOutputListener,
  env: NodeJS.ProcessEnv = process.env
): Promise<void> =>
  new Promise((resolve, reject) => {
    const child = spawn("git", ["clone", "--progress", url, destination], {
      env: {
        ...env,
        GIT_TERMINAL_PROMPT: "0",
        GIT_ASKPASS: "true",
        GIT_SSH_COMMAND: env.GIT_SSH_COMMAND ?? "ssh -oBatchMode=yes"
      }
    })
    const output = new GitCommandOutput(child, onOutput)
    const settle = (failure: CloneError | undefined): void => {
      output.flush()
      if (failure === undefined) {
        resolve()
      } else {
        reject(failure)
      }
    }
    child.once("error", (cause) => {
      settle(new CloneError(cause.message, undefined))
    })
    child.once("close", (code) => {
      if (code === 0) {
        settle(undefined)
        return
      }
      const stderrText = output.stderrLines.join("\n").trim()
      const message =
        stderrText.length > 0 ? stderrText : `git clone exited with code ${String(code)}`
      settle(new CloneError(message, classifyCloneFailure(stderrText)))
    })
  })

export const removeWorktree = (
  repoDir: string,
  path: string,
  env?: NodeJS.ProcessEnv,
  priority?: CommandPriority
): Promise<string> =>
  git("worktree", ["worktree", "remove", path, "--force"], repoDir, env, { priority })

export const rollbackFailedWorktree = async (
  repoDir: string,
  path: string,
  branch: string,
  env?: NodeJS.ProcessEnv
): Promise<boolean> => {
  const canonicalPath = (candidate: string): string => {
    try {
      return realpathSync(candidate)
    } catch {
      return resolve(candidate)
    }
  }
  const records = (
    await gitRaw("worktree-list", ["worktree", "list", "--porcelain", "-z"], repoDir, env)
  )
    .split("\0\0")
    .map((record) => record.split("\0"))
  const expectedPath = canonicalPath(path)
  const ownsCheckout = records.some((fields) => {
    const registeredPath = fields
      .find((field) => field.startsWith("worktree "))
      ?.slice("worktree ".length)
    return (
      registeredPath !== undefined &&
      canonicalPath(registeredPath) === expectedPath &&
      fields.includes(`branch refs/heads/${branch}`)
    )
  })
  if (!ownsCheckout) {
    return false
  }
  await removeWorktree(repoDir, path, env)
  await git("worktree-branch", ["branch", "-D", branch], repoDir, env)
  return true
}
