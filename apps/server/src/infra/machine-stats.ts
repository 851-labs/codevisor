import { execFile } from "node:child_process"
import { readFile, statfs } from "node:fs/promises"
import { cpus, freemem, homedir, totalmem, uptime } from "node:os"
import { promisify } from "node:util"

import type { MachineCpuSample, MachineStats, MachineStatsUsage } from "@codevisor/api"

const execFileAsync = promisify(execFile)

export interface CpuTimes {
  readonly idle: number
  readonly total: number
}

export interface MachineStatsReaders {
  readonly cores: () => number
  readonly cpuTimes: () => CpuTimes
  readonly memory: () => Promise<MachineStatsUsage>
  readonly disk: () => Promise<MachineStatsUsage | undefined>
  readonly uptimeSeconds: () => number
}

export interface MachineStatsSampler {
  readonly read: () => Promise<MachineStats>
  readonly stop: () => void
}

export interface MachineStatsSamplerOptions {
  readonly readers?: MachineStatsReaders
  readonly now?: () => number
  readonly every?: (tick: () => void, ms: number) => () => void
  readonly intervalMs?: number
  readonly historyLength?: number
  readonly idleMs?: number
}

export const cpuTimesOf = (
  list: ReadonlyArray<{
    readonly times: {
      readonly user: number
      readonly nice: number
      readonly sys: number
      readonly idle: number
      readonly irq: number
    }
  }>
): CpuTimes =>
  list.reduce(
    (sum, cpu) => ({
      idle: sum.idle + cpu.times.idle,
      total:
        sum.total + cpu.times.user + cpu.times.nice + cpu.times.sys + cpu.times.idle + cpu.times.irq
    }),
    { idle: 0, total: 0 }
  )

export const cpuPercentBetween = (before: CpuTimes, after: CpuTimes): number => {
  const total = after.total - before.total
  if (total <= 0) return 0
  return Math.min(Math.max((1 - (after.idle - before.idle) / total) * 100, 0), 100)
}

const vmStatPages = (output: string, label: string): number => {
  const match = new RegExp(`^${label}:\\s+(\\d+)`, "m").exec(output)
  return match === null ? 0 : Number(match[1])
}

export const darwinUsedMemory = (vmStat: string): number | undefined => {
  const pageSize = /page size of (\d+) bytes/.exec(vmStat)?.[1]
  if (pageSize === undefined) return undefined
  const pages =
    vmStatPages(vmStat, "Anonymous pages") -
    vmStatPages(vmStat, "Pages purgeable") +
    vmStatPages(vmStat, "Pages wired down") +
    vmStatPages(vmStat, "Pages occupied by compressor")
  return Math.max(pages, 0) * Number(pageSize)
}

export const linuxUsedMemory = (meminfo: string): MachineStatsUsage | undefined => {
  const kib = (label: string) => /^\s*(\d+)/.exec(meminfo.split(`${label}:`)[1] ?? "")?.[1]
  const total = kib("MemTotal")
  const available = kib("MemAvailable")
  if (total === undefined || available === undefined) return undefined
  return { usedBytes: (Number(total) - Number(available)) * 1024, totalBytes: Number(total) * 1024 }
}

/* v8 ignore start */
const systemMemory = async (): Promise<MachineStatsUsage> => {
  const totalBytes = totalmem()
  try {
    if (process.platform === "darwin") {
      const used = darwinUsedMemory((await execFileAsync("vm_stat")).stdout)
      if (used !== undefined) return { usedBytes: Math.min(used, totalBytes), totalBytes }
    }
    if (process.platform === "linux") {
      const usage = linuxUsedMemory(await readFile("/proc/meminfo", "utf8"))
      if (usage !== undefined) return usage
    }
  } catch {}
  return { usedBytes: totalBytes - freemem(), totalBytes }
}

const systemDisk = async (): Promise<MachineStatsUsage | undefined> => {
  try {
    const stats = await statfs(homedir())
    const totalBytes = stats.blocks * stats.bsize
    return { usedBytes: totalBytes - stats.bavail * stats.bsize, totalBytes }
  } catch {
    return undefined
  }
}

export const systemReaders: MachineStatsReaders = {
  cores: () => cpus().length,
  cpuTimes: () => cpuTimesOf(cpus()),
  memory: systemMemory,
  disk: systemDisk,
  uptimeSeconds: () => Math.round(uptime())
}

const everyInterval = (tick: () => void, ms: number): (() => void) => {
  const timer = setInterval(tick, ms)
  timer.unref()
  return () => clearInterval(timer)
}
/* v8 ignore stop */

export const makeMachineStatsSampler = (
  options: MachineStatsSamplerOptions = {}
): MachineStatsSampler => {
  /* v8 ignore start */
  const readers = options.readers ?? systemReaders
  const now = options.now ?? Date.now
  const every = options.every ?? everyInterval
  /* v8 ignore stop */
  const intervalMs = options.intervalMs ?? 3_000
  const historyLength = options.historyLength ?? 100
  const idleMs = options.idleMs ?? 60_000
  let previous: CpuTimes = { idle: 0, total: 0 }
  let history: Array<MachineCpuSample> = []
  let cancel: (() => void) | undefined
  let lastReadAt = 0

  const stop = (): void => {
    cancel?.()
    cancel = undefined
    history = []
  }

  const tick = (): void => {
    if (now() - lastReadAt >= idleMs) {
      stop()
      return
    }
    const current = readers.cpuTimes()
    history = [
      ...history,
      { at: new Date(now()).toISOString(), usedPercent: cpuPercentBetween(previous, current) }
    ].slice(-historyLength)
    previous = current
  }

  return {
    stop,
    read: async () => {
      lastReadAt = now()
      if (cancel === undefined) {
        previous = readers.cpuTimes()
        cancel = every(tick, intervalMs)
      }
      const [memory, disk] = await Promise.all([readers.memory(), readers.disk()])
      const latest = history.at(-1)
      return {
        sampledAt: new Date(now()).toISOString(),
        uptimeSeconds: readers.uptimeSeconds(),
        cpu: {
          cores: readers.cores(),
          ...(latest === undefined ? {} : { usedPercent: latest.usedPercent }),
          history
        },
        memory,
        ...(disk === undefined ? {} : { disk })
      }
    }
  }
}
