import { execFile } from "node:child_process"

import { withPriority } from "@codevisor/worktrees"

export type DirectorySize = (directory: string) => Promise<number | undefined>

export const directorySize: DirectorySize = (directory) => cachedDirectorySize(directory)

export const makeDirectorySize = (
  measure: DirectorySize = measureWithDu,
  now: () => number = Date.now
): DirectorySize => {
  const measurements = new Map<string, Measurement>()
  return (directory) => {
    const cached = measurements.get(directory)
    if (cached !== undefined && isFresh(cached, now())) return cached.bytes

    const measurement = { startedAt: now(), bytes: measure(directory) }
    measurements.set(directory, measurement)
    return measurement.bytes
  }
}

interface Measurement {
  readonly startedAt: number
  readonly bytes: Promise<number | undefined>
}

const freshForMs = 60_000
const bytesPerKilobyte = 1024

const isFresh = (measurement: Measurement, at: number): boolean =>
  at - measurement.startedAt < freshForMs

const measureWithDu: DirectorySize = (directory) => {
  const command = withPriority("du", ["-sk", directory], "utility")
  return new Promise((resolve) => {
    execFile(command.command, [...command.args], { encoding: "utf8" }, (_error, stdout) =>
      resolve(bytesFromDu(stdout))
    )
  })
}

const bytesFromDu = (stdout: string): number | undefined => {
  const kilobytes = Number.parseInt(stdout.trim().split("\n").at(-1) ?? "", 10)
  if (!Number.isFinite(kilobytes)) return undefined
  return kilobytes * bytesPerKilobyte
}

const cachedDirectorySize = makeDirectorySize()
