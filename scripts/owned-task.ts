import { spawn } from "node:child_process"

const OWNER_SIGNALS: readonly NodeJS.Signals[] = ["SIGINT", "SIGTERM", "SIGHUP"]

// The resource owner has its own process group. Its stdin pipe closes even
// when the calling shell or this launcher receives SIGKILL.
export function runOwnedTask(script: string, args: readonly string[]): void {
  const child = spawn(process.execPath, [script, ...args], {
    detached: true,
    stdio: ["pipe", "inherit", "inherit"]
  })
  const stop = () => child.stdin?.end()
  for (const signal of OWNER_SIGNALS) process.on(signal, stop)
  child.stdin?.on("error", () => {})
  const finish = (code: number | null) => {
    process.exitCode = code ?? 1
    for (const signal of OWNER_SIGNALS) process.off(signal, stop)
  }
  child.once("error", (error: Error) => {
    console.error(error.message)
    finish(1)
  })
  child.once("exit", finish)
}
