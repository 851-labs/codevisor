import { spawn } from "node:child_process"

const stopSignals: ReadonlyArray<NodeJS.Signals> = ["SIGINT", "SIGTERM", "SIGHUP"]

export function runOwnedTask(script: string, args: ReadonlyArray<string>): Promise<number> {
  const child = spawn(process.execPath, [script, ...args], {
    detached: true,
    stdio: ["pipe", "inherit", "inherit"]
  })
  const stop = (): void => {
    child.stdin.end()
  }
  for (const signal of stopSignals) process.on(signal, stop)
  child.stdin.on("error", () => {})

  return new Promise((resolve) => {
    const finish = (code: number | null): void => {
      for (const signal of stopSignals) process.off(signal, stop)
      process.exitCode = code ?? 1
      resolve(code ?? 1)
    }
    child.once("error", (error) => {
      console.error(error.message)
      finish(1)
    })
    child.once("exit", finish)
  })
}
