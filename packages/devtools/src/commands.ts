import { spawn, type SpawnOptions } from "node:child_process"

import { describeExit, waitForClose, waitForExit } from "./child-processes.ts"

export interface CommandRunner {
  readonly run: (command: string, args: ReadonlyArray<string>, cwd?: string) => Promise<void>
  readonly capture: (command: string, args: ReadonlyArray<string>) => Promise<string>
}

export function makeCommandRunner(repoRoot: string): CommandRunner {
  return {
    run: async (command, args, cwd = repoRoot) => {
      console.log(`\n$ ${command} ${args.join(" ")}`)
      const child = spawn(command, args, { cwd, env: process.env, stdio: "inherit" })
      const result = await waitForExit(child)
      if (result.code !== 0) throw new Error(`${command} failed (${describeExit(result)})`)
    },
    capture: async (command, args) => {
      const child = spawn(command, args, {
        cwd: repoRoot,
        env: process.env,
        stdio: ["ignore", "pipe", "inherit"]
      })
      let output = ""
      child.stdout.setEncoding("utf8")
      child.stdout.on("data", (chunk: string) => {
        output += chunk
      })
      const result = await waitForClose(child)
      if (result.code !== 0) throw new Error(`${command} failed (${describeExit(result)})`)
      return output
    }
  }
}

export async function runCommand(
  command: string,
  args: ReadonlyArray<string>,
  options: SpawnOptions = {}
): Promise<void> {
  const child = spawn(command, args, { ...options, stdio: "inherit" })
  const result = await waitForExit(child)
  if (result.code !== 0) throw new Error(`${command} failed (${describeExit(result)})`)
}

export async function captureCommand(
  command: string,
  args: ReadonlyArray<string>,
  options: SpawnOptions = {}
): Promise<string> {
  const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "ignore"] })
  let output = ""
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk: string) => {
    output += chunk
  })
  const result = await waitForClose(child)
  if (result.code !== 0) throw new Error(`${command} failed (${describeExit(result)})`)
  return output
}
