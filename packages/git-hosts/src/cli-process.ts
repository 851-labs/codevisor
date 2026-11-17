import { spawn } from "node:child_process"

export interface CliResult {
  readonly exitCode: number | null
  readonly stdout: string
  readonly stderr: string
  readonly output: string
}

export interface CliRunOptions {
  readonly timeoutMs: number
  readonly cwd?: string
  readonly stdin?: string
}

export const runCli = (
  path: string,
  args: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv,
  { timeoutMs, cwd, stdin }: CliRunOptions
): Promise<CliResult> =>
  new Promise((resolve) => {
    const child = spawn(path, [...args], {
      env,
      stdio: ["pipe", "pipe", "pipe"],
      timeout: timeoutMs,
      ...(cwd === undefined ? {} : { cwd })
    })
    const captured = { stdout: "", stderr: "", output: "" }
    child.stdin.on("error", () => undefined)
    child.stdin.end(stdin)
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    child.stdout.on("data", (chunk: string) => {
      captured.stdout += chunk
      captured.output += chunk
    })
    child.stderr.on("data", (chunk: string) => {
      captured.stderr += chunk
      captured.output += chunk
    })
    child.once("error", (cause) => {
      resolve({ exitCode: null, ...captured, output: captured.output + cause.message })
    })
    child.once("close", (exitCode) => resolve({ exitCode, ...captured }))
  })
