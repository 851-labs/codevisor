import { spawn } from "node:child_process"
import process from "node:process"

import { ensureGhosttyFramework } from "./ghostty-artifact.mjs"

export async function bootstrapDevelopment(repoRoot, options = {}) {
  await run("bun", ["install", "--frozen-lockfile"], repoRoot, options.environment)
  if (options.ghostty === true) {
    await ensureGhosttyFramework(repoRoot, options.environment)
  }
}

function run(command, arguments_, cwd, environment = process.env) {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawn(command, arguments_, { cwd, env: environment, stdio: "inherit" })
  return new Promise((resolve, reject) => {
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
