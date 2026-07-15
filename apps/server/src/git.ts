import { execFile, spawn } from "node:child_process"
import { readFile } from "node:fs/promises"
import { join } from "node:path"

import type { BranchDiffTotals } from "@codevisor/api"

export class GitError extends Error {
  constructor(
    readonly operation: string,
    message: string
  ) {
    super(message)
    this.name = "GitError"
  }
}

const git = (operation: string, args: ReadonlyArray<string>, cwd: string): Promise<string> =>
  new Promise((resolve, reject) => {
    execFile("git", args, { cwd }, (error, stdout, stderr) => {
      if (error !== null) {
        reject(new GitError(operation, stderr.trim().length > 0 ? stderr.trim() : error.message))
        return
      }
      resolve(stdout.trim())
    })
  })

const gitRaw = (operation: string, args: ReadonlyArray<string>, cwd: string): Promise<string> =>
  new Promise((resolve, reject) => {
    execFile("git", args, { cwd }, (error, stdout, stderr) => {
      if (error !== null) {
        reject(new GitError(operation, stderr.trim().length > 0 ? stderr.trim() : error.message))
        return
      }
      resolve(stdout)
    })
  })

export const isGitWorkTree = async (dir: string): Promise<boolean> => {
  try {
    return (await git("rev-parse", ["rev-parse", "--is-inside-work-tree"], dir)) === "true"
  } catch {
    return false
  }
}

export type GitOutputStream = "stdout" | "stderr"
export type GitOutputListener = (stream: GitOutputStream, line: string) => void

/// Matches ANSI escape sequences - CSI (colors, cursor moves, erase), OSC
/// (titles/links), and single-character escapes - that TUI-style checkout
/// hooks emit. Setup logs render as plain text, so these are stripped.
// eslint-disable-next-line no-control-regex
// oxlint-disable no-control-regex
const ansiEscapePattern =
  /\u001B(?:\[[0-9:;<=>?]*[ -/]*[@-~]|\][^\u0007\u001B]*(?:\u0007|\u001B\\)?|[@-Z\\^_])/g
// oxlint-enable no-control-regex

/// Strips ANSI escapes and stray control characters and trims trailing
/// whitespace, leaving a human-readable log line (possibly empty).
export const sanitizeGitOutputLine = (line: string): string =>
  line
    .replace(ansiEscapePattern, "")
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "")
    .trimEnd()

/// Splits a chunked byte stream into lines, invoking `onLine` per complete
/// line; call `flush()` after the stream ends to emit a trailing partial line.
/// A bare carriage return also ends a line: progress-style output that
/// repaints in place becomes discrete lines instead of one endless one.
const lineSplitter = (
  onLine: (line: string) => void
): { push: (chunk: string) => void; flush: () => void } => {
  let buffered = ""
  return {
    push: (chunk) => {
      buffered += chunk
      const lines = buffered.split(/\r?\n|\r/)
      // split always yields at least one element, so pop never returns undefined.
      buffered = lines.pop() as string
      for (const line of lines) {
        onLine(line)
      }
    },
    flush: () => {
      if (buffered.length > 0) {
        onLine(buffered)
        buffered = ""
      }
    }
  }
}

/// Returns the ref new worktrees should be cut from: the remote-tracking
/// `origin/main` when it exists (so worktrees start from the last-fetched
/// remote state even when the local checkout is behind or has drifted),
/// otherwise undefined so `git worktree add` falls back to HEAD.
export const worktreeStartPoint = async (repoDir: string): Promise<string | undefined> => {
  try {
    await git(
      "rev-parse",
      ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"],
      repoDir
    )
    return "origin/main"
  } catch {
    return undefined
  }
}

const branchDiffBaseRefs = ["origin/HEAD", "origin/main", "origin/master", "main", "master"]

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

// Mirrors GitBranchDiff.totals on macOS: compare the merge-base with the
// default branch through the working tree, then count text lines in untracked
// files as additions. Non-git directories and command failures stay hidden.
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
      } catch {
        // Try the next conventional default-branch ref.
      }
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

/// Runs `git worktree add`, streaming stdout/stderr lines (including output
/// from post-checkout hooks) to `onOutput` as they arrive. Rejects with a
/// GitError carrying the collected stderr when git exits non-zero. When
/// `startPoint` is given the new branch is cut from that ref instead of HEAD.
export const addWorktree = (
  repoDir: string,
  path: string,
  branch: string,
  onOutput?: GitOutputListener,
  startPoint?: string
): Promise<void> =>
  new Promise((resolve, reject) => {
    const args = ["worktree", "add", path, "-b", branch]
    if (startPoint !== undefined) {
      args.push(startPoint)
    }
    const child = spawn("git", args, { cwd: repoDir })
    const stderrLines: Array<string> = []
    const listen = (stream: GitOutputStream) => {
      // Progress-style output repaints the same line many times; emit each
      // distinct frame once and drop lines that were pure escape codes.
      let lastLine: string | undefined
      return lineSplitter((raw) => {
        const line = sanitizeGitOutputLine(raw)
        if (line.length === 0 || line === lastLine) {
          return
        }
        lastLine = line
        if (stream === "stderr") {
          stderrLines.push(line)
        }
        onOutput?.(stream, line)
      })
    }
    const stdout = listen("stdout")
    const stderr = listen("stderr")
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    child.stdout.on("data", stdout.push)
    child.stderr.on("data", stderr.push)
    const settle = (failure: GitError | undefined): void => {
      stdout.flush()
      stderr.flush()
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
      const stderrText = stderrLines.join("\n").trim()
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

/// Failure categories for clone errors, matched against git's stderr. The
/// server maps these onto HTTP responses and project.setup events so clients
/// can show actionable guidance instead of raw git output.
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

/// Clones a remote into `destination`, streaming progress lines. Credential
/// prompts are the top failure mode on headless machines: GIT_TERMINAL_PROMPT
/// and ssh BatchMode make an auth-challenged clone fail fast with a
/// classifiable error instead of hanging the request forever.
export const cloneRepository = (
  url: string,
  destination: string,
  onOutput?: GitOutputListener
): Promise<void> =>
  new Promise((resolve, reject) => {
    const child = spawn("git", ["clone", "--progress", url, destination], {
      env: {
        ...process.env,
        GIT_TERMINAL_PROMPT: "0",
        GIT_ASKPASS: "true",
        GIT_SSH_COMMAND: process.env.GIT_SSH_COMMAND ?? "ssh -oBatchMode=yes"
      }
    })
    const stderrLines: Array<string> = []
    const listen = (stream: GitOutputStream) => {
      let lastLine: string | undefined
      return lineSplitter((raw) => {
        const line = sanitizeGitOutputLine(raw)
        if (line.length === 0 || line === lastLine) {
          return
        }
        lastLine = line
        if (stream === "stderr") {
          stderrLines.push(line)
        }
        onOutput?.(stream, line)
      })
    }
    const stdout = listen("stdout")
    const stderr = listen("stderr")
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    child.stdout.on("data", stdout.push)
    child.stderr.on("data", stderr.push)
    const settle = (failure: CloneError | undefined): void => {
      stdout.flush()
      stderr.flush()
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
      const stderrText = stderrLines.join("\n").trim()
      const message =
        stderrText.length > 0 ? stderrText : `git clone exited with code ${String(code)}`
      settle(new CloneError(message, classifyCloneFailure(stderrText)))
    })
  })

export const removeWorktree = (repoDir: string, path: string): Promise<string> =>
  git("worktree", ["worktree", "remove", path, "--force"], repoDir)
