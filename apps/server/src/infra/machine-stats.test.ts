import { describe, expect, it } from "vitest"

import {
  cpuModelOf,
  cpuPercentBetween,
  cpuTimesOf,
  darwinGpu,
  darwinUsedMemory,
  linuxUsedMemory,
  makeMachineStatsSampler,
  nvidiaGpu,
  type CpuTimes,
  type GpuReading,
  type MachineStatsReaders
} from "./machine-stats.js"

const settle = () => new Promise<void>((resolve) => setImmediate(resolve))

const sampler = (cpu: Array<CpuTimes>, disk = true, gpu: Array<GpuReading | undefined> = []) => {
  let now = Date.parse("2026-10-20T12:00:00.000Z")
  let tick: (() => void) | undefined
  let cancelled = 0
  let gpuReads = 0
  const readers: MachineStatsReaders = {
    cores: () => 8,
    cpuModel: () => "Apple M1 Pro",
    cpuTimes: () => cpu.shift() ?? { idle: 0, total: 0 },
    gpu: async () => {
      gpuReads += 1
      return gpu.shift()
    },
    memory: async () => ({ usedBytes: 6, totalBytes: 16 }),
    disk: async () => (disk ? { usedBytes: 200, totalBytes: 500 } : undefined),
    uptimeSeconds: () => 3_600
  }
  const stats = makeMachineStatsSampler({
    readers,
    now: () => now,
    every: (callback) => {
      tick = callback
      return () => {
        cancelled += 1
        tick = undefined
      }
    },
    historyLength: 2
  })
  return {
    stats,
    advance: async (ms: number) => {
      now += ms
      tick?.()
      await settle()
    },
    running: () => tick !== undefined,
    cancelled: () => cancelled,
    gpuReads: () => gpuReads
  }
}

describe("machine stats", () => {
  it("sums CPU time across cores and turns two readings into a busy percentage", () => {
    const times = cpuTimesOf([
      { times: { user: 10, nice: 0, sys: 5, idle: 80, irq: 5 } },
      { times: { user: 20, nice: 1, sys: 4, idle: 70, irq: 5 } }
    ])
    expect(times).toEqual({ idle: 150, total: 200 })
    expect(cpuModelOf([{ model: "Intel(R) Core(TM)  i9 CPU @ 2.40GHz " }])).toBe(
      "Intel(R) Core(TM) i9 CPU @ 2.40GHz"
    )
    expect(cpuModelOf([{ model: "" }])).toBeUndefined()
    expect(cpuModelOf([])).toBeUndefined()
    expect(cpuPercentBetween({ idle: 0, total: 0 }, { idle: 75, total: 100 })).toBe(25)
    expect(cpuPercentBetween({ idle: 10, total: 100 }, { idle: 10, total: 100 })).toBe(0)
    expect(cpuPercentBetween({ idle: 50, total: 100 }, { idle: 0, total: 200 })).toBe(100)
  })

  it("counts app, wired and compressed memory from vm_stat, like Activity Monitor", () => {
    const vmStat = [
      "Mach Virtual Memory Statistics: (page size of 16384 bytes)",
      "Pages wired down:                             100.",
      "Pages purgeable:                               10.",
      "Anonymous pages:                              300.",
      "Pages occupied by compressor:                  50."
    ].join("\n")
    expect(darwinUsedMemory(vmStat)).toBe(440 * 16_384)
    expect(darwinUsedMemory("no page size")).toBeUndefined()
    expect(darwinUsedMemory("(page size of 4096 bytes)\nPages purgeable: 9.")).toBe(0)
  })

  it("reads used memory from MemAvailable on Linux", () => {
    expect(
      linuxUsedMemory("MemTotal:       16000 kB\nMemFree: 1 kB\nMemAvailable:    6000 kB\n")
    ).toEqual({ usedBytes: 10_000 * 1024, totalBytes: 16_000 * 1024 })
    expect(linuxUsedMemory("MemTotal: 16000 kB\n")).toBeUndefined()
  })

  it("samples from the moment it's created and keeps recent CPU history without being read", async () => {
    const { stats, advance, running, cancelled } = sampler([
      { idle: 0, total: 0 },
      { idle: 90, total: 100 },
      { idle: 140, total: 200 },
      { idle: 140, total: 300 }
    ])
    expect(running()).toBe(true)
    expect(await stats.read()).toEqual({
      sampledAt: "2026-10-20T12:00:00.000Z",
      uptimeSeconds: 3_600,
      cpu: { model: "Apple M1 Pro", cores: 8, history: [] },
      memory: { usedBytes: 6, totalBytes: 16 },
      disk: { usedBytes: 200, totalBytes: 500 }
    })

    await advance(3_000)
    await advance(60_000)
    await advance(3_000)
    const later = await stats.read()
    expect(later.cpu.usedPercent).toBe(100)
    expect(later.cpu.history).toEqual([
      { at: "2026-10-20T12:01:03.000Z", usedPercent: 50 },
      { at: "2026-10-20T12:01:06.000Z", usedPercent: 100 }
    ])

    stats.stop()
    expect(running()).toBe(false)
    expect(cancelled()).toBe(1)
  })

  it("samples every few seconds by default", () => {
    const intervals: Array<number> = []
    makeMachineStatsSampler({
      readers: {
        cores: () => 1,
        cpuModel: () => undefined,
        cpuTimes: () => ({ idle: 0, total: 0 }),
        gpu: async () => undefined,
        memory: async () => ({ usedBytes: 1, totalBytes: 2 }),
        disk: async () => undefined,
        uptimeSeconds: () => 1
      },
      now: () => 0,
      every: (_tick, ms) => {
        intervals.push(ms)
        return () => undefined
      }
    })
    expect(intervals).toEqual([3_000])
  })

  it("reads GPU use from ioreg on macOS and nvidia-smi on Linux", () => {
    const ioreg = [
      '"PerformanceStatistics" = {"Tiler Utilization %"=12,"Device Utilization %"=37,"Renderer Utilization %"=12}',
      '"model" = "Apple M1 Pro"',
      '"gpu-core-count" = 16'
    ].join("\n")
    expect(darwinGpu(ioreg)).toEqual({ usedPercent: 37, model: "Apple M1 Pro", cores: 16 })
    expect(darwinGpu('"Device Utilization %"=140')).toEqual({ usedPercent: 100 })
    expect(darwinGpu("no accelerator")).toBeUndefined()
    expect(nvidiaGpu("42, NVIDIA GeForce RTX 4090\n7, Second GPU\n")).toEqual({
      usedPercent: 42,
      model: "NVIDIA GeForce RTX 4090"
    })
    expect(nvidiaGpu("42\n")).toEqual({ usedPercent: 42 })
    expect(nvidiaGpu("[N/A], GPU\n")).toBeUndefined()
    expect(nvidiaGpu("")).toBeUndefined()
  })

  it("samples the GPU alongside the CPU and drops a reading that lands after it stopped", async () => {
    const { stats, advance } = sampler(
      [
        { idle: 0, total: 0 },
        { idle: 50, total: 100 }
      ],
      true,
      [
        { usedPercent: 10, model: "Apple M1 Pro", cores: 16 },
        { usedPercent: 40 },
        { usedPercent: 70 }
      ]
    )
    await settle()
    expect((await stats.read()).gpu).toEqual({
      model: "Apple M1 Pro",
      cores: 16,
      usedPercent: 10,
      history: [{ at: "2026-10-20T12:00:00.000Z", usedPercent: 10 }]
    })
    await advance(3_000)
    expect((await stats.read()).gpu).toEqual({
      usedPercent: 40,
      history: [
        { at: "2026-10-20T12:00:00.000Z", usedPercent: 10 },
        { at: "2026-10-20T12:00:03.000Z", usedPercent: 40 }
      ]
    })

    const late = sampler([], true, [{ usedPercent: 70 }])
    late.stats.stop()
    await settle()
    expect((await late.stats.read()).gpu).toBeUndefined()
  })

  it("stops probing a machine with no GPU but rides out a missed reading on one that has it", async () => {
    const none = sampler([], true, [undefined])
    await settle()
    await none.advance(3_000)
    await none.advance(3_000)
    expect(none.gpuReads()).toBe(1)
    expect((await none.stats.read()).gpu).toBeUndefined()

    const flaky = sampler([], true, [{ usedPercent: 20 }, undefined, { usedPercent: 30 }])
    await settle()
    await flaky.advance(3_000)
    await flaky.advance(3_000)
    expect(flaky.gpuReads()).toBe(3)
    expect((await flaky.stats.read()).gpu?.usedPercent).toBe(30)
  })

  it("leaves out the disk when it can't be read", async () => {
    const { stats } = sampler([], false)
    expect((await stats.read()).disk).toBeUndefined()
  })
})
