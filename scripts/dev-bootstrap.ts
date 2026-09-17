import { spawn } from "node:child_process"
import process from "node:process"

import { ensureChromium } from "./chromium-artifact.ts"
import { ensureGhosttyFramework } from "./ghostty-artifact.ts"

export interface BootstrapDevelopmentOptions {
  environment?: NodeJS.ProcessEnv | undefined
  ghostty?: boolean | undefined
  architectures?: string[] | undefined
}

export async function bootstrapDevelopment(
  repoRoot: string,
  options: BootstrapDevelopmentOptions = {}
): Promise<void> {
  await run("bun", ["install", "--frozen-lockfile"], repoRoot, options.environment)
  if (options.ghostty === true) {
    await ensureGhosttyFramework(repoRoot, options.environment)
    await ensureChromium(repoRoot, options.environment, options.architectures)
  }
}

function run(
  command: string,
  arguments_: readonly string[],
  cwd: string,
  environment: NodeJS.ProcessEnv = process.env
): Promise<void> {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawn(command, arguments_, { cwd, env: environment, stdio: "inherit" })
  return new Promise<void>((resolve, reject) => {
    child.once("exit", (code, signal) => {
      if (code === 0) {
        resolve()
        return
      }
      reject(
        new Error(
          `${command} failed (${signal === null ? `code ${code ?? 1}` : `signal ${signal}`})`
        )
      )
    })
  })
}
