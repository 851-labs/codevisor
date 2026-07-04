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

export const addWorktree = (repoDir: string, path: string, branch: string): Promise<string> =>
  git("worktree", ["worktree", "add", path, "-b", branch], repoDir)

export const removeWorktree = (repoDir: string, path: string): Promise<string> =>
  git("worktree", ["worktree", "remove", path, "--force"], repoDir)
