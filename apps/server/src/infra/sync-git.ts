import { spawn } from "node:child_process"

import { gitExecutable } from "@codevisor/worktrees"

export class GitCommandError extends Error {
  constructor(
    readonly args: ReadonlyArray<string>,
    readonly stderr: string,
    readonly exitCode: number | null
  ) {
    super(gitFailureMessage(stderr, exitCode))
  }
}

const gitFailureMessage = (stderr: string, exitCode: number | null): string => {
  const lines = stderr
    .split("\n")
    .map((line) => line.replace(/^(error|fatal):\s*/, "").trim())
    .filter((line) => line !== "")
  return lines.length > 0 ? lines.join("\n") : `git exited with ${exitCode}`
}

export interface GitOptions {
  readonly env?: NodeJS.ProcessEnv
  readonly cwd?: string
}

export const git = async (args: ReadonlyArray<string>, options: GitOptions = {}): Promise<string> =>
  (await runGit(args, undefined, options)).toString("utf8")

export const gitWithInput = async (
  args: ReadonlyArray<string>,
  input: Buffer | string,
  options: GitOptions = {}
): Promise<Buffer> => runGit(args, input, options)

const runGit = (
  args: ReadonlyArray<string>,
  input: Buffer | string | undefined,
  options: GitOptions
): Promise<Buffer> =>
  new Promise((resolve, reject) => {
    const child = spawn(gitExecutable(options.env), [...args], {
      env: { ...process.env, ...options.env, GIT_TERMINAL_PROMPT: "0" },
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
      stdio: ["pipe", "pipe", "pipe"]
    })
    const stdout: Buffer[] = []
    const stderr: Buffer[] = []
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk))
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk))
    child.once("error", reject)
    child.once("close", (code) => {
      if (code === 0) resolve(Buffer.concat(stdout))
      else reject(new GitCommandError(args, Buffer.concat(stderr).toString("utf8"), code))
    })
    child.stdin.end(input)
  })
