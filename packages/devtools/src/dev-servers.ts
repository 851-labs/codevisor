import { readFileSync } from "node:fs"
import { join } from "node:path"

import { delay, type ExitingProcess, waitForExit } from "./child-processes.ts"

const healthPollMilliseconds = 250
const shutdownRequestMilliseconds = 1_000
const shutdownGraceMilliseconds = 2_000

export type DevServer = readonly [port: number, child: StoppableProcess]

export interface StoppableProcess extends ExitingProcess {
  readonly kill: (signal?: NodeJS.Signals) => boolean
}

export async function waitForHealth(
  port: number | (() => number),
  child: ExitingProcess,
  attempts = 120
): Promise<void> {
  const currentPort = typeof port === "function" ? port : () => port
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (child.exitCode !== null) throw new Error("Codevisor server exited before becoming healthy")
    if (await isHealthy(currentPort())) return

    await delay(healthPollMilliseconds)
  }
  throw new Error(`Timed out waiting for the Codevisor server on port ${currentPort()}`)
}

export function claimedServerPort(dataDirectory: string, fallback: number): number {
  try {
    const { port } = JSON.parse(readFileSync(join(dataDirectory, "server-port.json"), "utf8"))
    return Number.isInteger(port) && port > 0 ? port : fallback
  } catch {
    return fallback
  }
}

export async function shutdownDevServers(servers: ReadonlyArray<DevServer>): Promise<void> {
  for (const [port, child] of servers) await requestShutdown(port, child)

  await Promise.race([
    Promise.all(servers.map(([, child]) => waitForExit(child))),
    delay(shutdownGraceMilliseconds)
  ])
  for (const [, child] of servers) {
    if (child.exitCode === null) child.kill("SIGTERM")
  }
}

async function isHealthy(port: number): Promise<boolean> {
  try {
    return (await fetch(`http://127.0.0.1:${port}/v1/health`)).ok
  } catch {
    return false
  }
}

async function requestShutdown(port: number, child: StoppableProcess): Promise<void> {
  try {
    await fetch(`http://127.0.0.1:${port}/v1/shutdown`, {
      method: "POST",
      signal: AbortSignal.timeout(shutdownRequestMilliseconds)
    })
  } catch {
    child.kill("SIGTERM")
  }
}
