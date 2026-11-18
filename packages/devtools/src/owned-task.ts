import { spawn } from "node:child_process"
import { Readable, Writable } from "node:stream"

const stopSignals: ReadonlyArray<NodeJS.Signals> = ["SIGINT", "SIGTERM", "SIGHUP"]
const statusDescriptor = 3
const lifelineDescriptor = 4
const detachedTask = `( "$@" <&${lifelineDescriptor} ${lifelineDescriptor}<&- ${statusDescriptor}>&-; /bin/echo $? >&${statusDescriptor} 2>/dev/null ) &`

export function runOwnedTask(script: string, args: ReadonlyArray<string>): Promise<number> {
  const host = spawn("/bin/sh", ["-c", detachedTask, "sh", process.execPath, script, ...args], {
    detached: true,
    stdio: ["ignore", "inherit", "inherit", "pipe", "pipe"]
  })
  const status = host.stdio[statusDescriptor]
  const lifeline = host.stdio[lifelineDescriptor]
  if (!(status instanceof Readable) || !(lifeline instanceof Writable))
    throw new Error("The owned task's pipes could not be opened")

  const stop = (): void => {
    lifeline.end()
  }
  for (const signal of stopSignals) process.on(signal, stop)
  lifeline.on("error", () => {})

  return new Promise((resolve) => {
    let reported = ""
    const finish = (code: number): void => {
      for (const signal of stopSignals) process.off(signal, stop)
      process.exitCode = code
      resolve(code)
    }
    host.once("error", (error) => {
      console.error(error.message)
      finish(1)
    })
    status.on("data", (chunk: Buffer) => {
      reported += chunk.toString("utf8")
    })
    status.once("end", () => finish(exitCodeOf(reported)))
  })
}

function exitCodeOf(reported: string): number {
  return /^\d+\s*$/.test(reported) ? Number(reported) : 1
}
