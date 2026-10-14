import { spawn } from "node:child_process"

export function runOwnedTask(script, args) {
  const child = spawn(process.execPath, [script, ...args], {
    detached: true,
    stdio: ["pipe", "inherit", "inherit"]
  })
  const stop = () => child.stdin.end()
  const signals = ["SIGINT", "SIGTERM", "SIGHUP"]
  for (const signal of signals) process.on(signal, stop)
  child.stdin.on("error", () => {})
  const finish = (code) => {
    process.exitCode = code ?? 1
    for (const signal of signals) process.off(signal, stop)
  }
  child.once("error", (error) => {
    console.error(error.message)
    finish(1)
  })
  child.once("exit", finish)
}
