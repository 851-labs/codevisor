import { spawn } from "node:child_process"

export interface ProcessResult {
  readonly code: number | null
  readonly stdout: string
  readonly stderr: string
}

export interface RunOptions {
  readonly timeoutMs: number
  readonly env?: Readonly<Record<string, string | undefined>>
}

export type RunProcess = (
  command: string,
  args: ReadonlyArray<string>,
  options: RunOptions
) => Promise<ProcessResult>

export const runProcess: RunProcess = (command, args, options) =>
  new Promise((resolve, reject) => {
    const child = spawn(command, [...args], {
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
      timeout: options.timeoutMs
    })
    const stdout: Array<Buffer> = []
    const stderr: Array<Buffer> = []
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk))
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk))
    child.once("error", reject)
    child.once("close", (code) => {
      resolve({
        code,
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8")
      })
    })
  })
