import { execFile } from "node:child_process"
import { readFile, statfs } from "node:fs/promises"
import { cpus, freemem, homedir, totalmem, uptime } from "node:os"
import { promisify } from "node:util"

import type { MachineLoadSample, MachineStats, MachineStatsUsage } from "@codevisor/api"

const execFileAsync = promisify(execFile)

export interface CpuTimes {
  readonly idle: number
  readonly total: number
}

export interface GpuReading {
  readonly usedPercent: number
  readonly model?: string
  readonly cores?: number
}

export interface MachineStatsReaders {
  readonly cores: () => number
  readonly cpuTimes: () => CpuTimes
  readonly gpu: () => Promise<GpuReading | undefined>
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

export const darwinGpu = (ioreg: string): GpuReading | undefined => {
  const used = /"Device Utilization %"=(\d+)/.exec(ioreg)?.[1]
  if (used === undefined) return undefined
  const model = /"model" = "([^"]+)"/.exec(ioreg)?.[1]
  const cores = /"gpu-core-count" = (\d+)/.exec(ioreg)?.[1]
  return {
    usedPercent: Math.min(Number(used), 100),
    ...(model === undefined ? {} : { model }),
    ...(cores === undefined ? {} : { cores: Number(cores) })
  }
}

export const nvidiaGpu = (csv: string): GpuReading | undefined => {
  const [used, model] = csv.split(/,|\n/).map((part) => part.trim())
  const usedPercent = Number.parseFloat(String(used))
  if (!Number.isFinite(usedPercent)) return undefined
  return { usedPercent: Math.min(usedPercent, 100), ...(model ? { model } : {}) }
}

/* v8 ignore start */
const systemGpu = async (): Promise<GpuReading | undefined> => {
  try {
    if (process.platform === "darwin") {
      return darwinGpu(
        (
          await execFileAsync("/usr/sbin/ioreg", [
            "-r",
            "-d",
            "1",
            "-w",
            "0",
            "-c",
            "IOAccelerator"
          ])
        ).stdout
      )
    }
    if (process.platform === "linux") {
      return nvidiaGpu(
        (
          await execFileAsync("nvidia-smi", [
            "--query-gpu=utilization.gpu,name",
            "--format=csv,noheader,nounits"
          ])
        ).stdout
      )
    }
  } catch {}
  return undefined
}

const systemMemory = async (): Promise<MachineStatsUsage> => {
  const totalBytes = totalmem()
  try {
    if (process.platform === "darwin") {
      const used = darwinUsedMemory((await execFileAsync("/usr/bin/vm_stat")).stdout)
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
  gpu: systemGpu,
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
  const isoNow = () => new Date(now()).toISOString()
  let previous = readers.cpuTimes()
  let history: Array<MachineLoadSample> = []
  let gpu: GpuReading | undefined
  let gpuHistory: Array<MachineLoadSample> = []
  let probesGpu = true
  let stopped = false

  const sampleGpu = async (at: string): Promise<void> => {
    if (!probesGpu) return
    const reading = await readers.gpu()
    if (stopped) return
    if (reading === undefined) {
      probesGpu = gpu !== undefined
      return
    }
    gpu = reading
    gpuHistory = [...gpuHistory, { at, usedPercent: reading.usedPercent }].slice(-historyLength)
  }

  const tick = (): void => {
    const at = isoNow()
    const current = readers.cpuTimes()
    history = [...history, { at, usedPercent: cpuPercentBetween(previous, current) }].slice(
      -historyLength
    )
    previous = current
    void sampleGpu(at)
  }

  void sampleGpu(isoNow())
  const cancel = every(tick, intervalMs)

  return {
    stop: () => {
      stopped = true
      cancel()
    },
    read: async () => {
      const [memory, disk] = await Promise.all([readers.memory(), readers.disk()])
      const latest = history.at(-1)
      return {
        sampledAt: isoNow(),
        uptimeSeconds: readers.uptimeSeconds(),
        cpu: {
          cores: readers.cores(),
          ...(latest === undefined ? {} : { usedPercent: latest.usedPercent }),
          history
        },
        ...(gpu === undefined
          ? {}
          : {
              gpu: {
                ...(gpu.model === undefined ? {} : { model: gpu.model }),
                ...(gpu.cores === undefined ? {} : { cores: gpu.cores }),
                usedPercent: gpu.usedPercent,
                history: gpuHistory
              }
            }),
        memory,
        ...(disk === undefined ? {} : { disk })
      }
    }
  }
}
