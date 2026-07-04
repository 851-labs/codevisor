import { execFile, spawn } from "node:child_process"

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
const ansiEscapePattern =
  /\u001B(?:\[[0-9:;<=>?]*[ -/]*[@-~]|\][^\u0007\u001B]*(?:\u0007|\u001B\\)?|[@-Z\\^_])/g

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

/// Runs `git worktree add`, streaming stdout/stderr lines (including output
/// from post-checkout hooks) to `onOutput` as they arrive. Rejects with a
/// GitError carrying the collected stderr when git exits non-zero.
export const addWorktree = (
  repoDir: string,
  path: string,
  branch: string,
  onOutput?: GitOutputListener
): Promise<void> =>
  new Promise((resolve, reject) => {
    const child = spawn("git", ["worktree", "add", path, "-b", branch], { cwd: repoDir })
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

export const removeWorktree = (repoDir: string, path: string): Promise<string> =>
  git("worktree", ["worktree", "remove", path, "--force"], repoDir)
