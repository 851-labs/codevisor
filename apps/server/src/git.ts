import { execFile } from "node:child_process"

export class GitError extends Error {
  constructor(
    readonly operation: string,
    message: string
  ) {
    super(message)
    this.name = "GitError"
  }
}

const git = (args: ReadonlyArray<string>, cwd: string): Promise<string> =>
  new Promise((resolve, reject) => {
    execFile("git", args, { cwd }, (error, stdout, stderr) => {
      if (error !== null) {
        reject(new GitError(args[0] ?? "git", stderr.trim().length > 0 ? stderr.trim() : error.message))
        return
      }
      resolve(stdout.trim())
    })
  })

export const isGitWorkTree = async (dir: string): Promise<boolean> => {
  try {
    return (await git(["rev-parse", "--is-inside-work-tree"], dir)) === "true"
  } catch {
    return false
  }
}

export const addWorktree = (repoDir: string, path: string, branch: string): Promise<string> =>
  git(["worktree", "add", path, "-b", branch], repoDir)
