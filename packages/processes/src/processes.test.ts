import { spawn } from "node:child_process"
import { once } from "node:events"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import {
  parseProcessTable,
  processIdentity,
  processTree,
  readProcessTable,
  sameProcess,
  stopProcesses,
  stopProcessTree,
  trackProcessTree
} from "./index.mjs"

const entry = (pid: number, ppid = 1, pgid = pid, startedAt = "first") => ({
  pid,
  ppid,
  pgid,
  startedAt,
  state: "S",
  command: `command-${pid}`
})
const fakeSystem = (initial: ReturnType<typeof entry>[]) => {
  let table = initial
  let clock = 0
  const signals: Array<[number, string]> = []
  const system = {
    list: async () => table,
    now: () => clock,
    sleep: async (ms: number) => {
      clock += ms
    },
    signal: (pid: number, signal: NodeJS.Signals) => {
      signals.push([pid, signal])
      table = table.filter((p) => p.pid !== pid)
    }
  }
  return {
    system,
    signals,
    set: (next: typeof initial) => {
      table = next
    }
  }
}

describe("owned process shutdown", () => {
  it("allows retry after a failed shutdown snapshot", async () => {
    const stop = vi
      .fn()
      .mockRejectedValueOnce(new Error("process table unavailable"))
      .mockResolvedValue(undefined)
    const tree = await trackProcessTree(30, { list: async () => [], stop })
    try {
      await expect(tree.stop()).rejects.toThrow("process table unavailable")
      await tree.stop()
      expect(stop).toHaveBeenCalledTimes(2)
    } finally {
      tree.dispose()
    }
  })
  it("keeps tracking after a failed poll and retains children after the owner exits", async () => {
    vi.useFakeTimers()
    const list = vi
      .fn()
      .mockResolvedValueOnce([entry(30), entry(31, 30, 30)])
      .mockRejectedValueOnce(new Error("ps interrupted"))
      .mockResolvedValue([entry(31, 1, 30), entry(32, 1, 30)])
    const stop = vi.fn(async () => {})
    const tree = await trackProcessTree(30, { list, stop, detached: true })
    try {
      await vi.advanceTimersByTimeAsync(500)
      await tree.stop({ includeRoot: false })
      expect(stop).toHaveBeenCalledWith(
        [31, 32].map((pid) => ({ pid, ppid: 1, pgid: 30, startedAt: "first", state: "S" })),
        expect.anything()
      )
    } finally {
      tree.dispose()
      vi.useRealTimers()
    }
  })
  it("parses birth time and rejects PID reuse and zombies", () => {
    expect(
      parseProcessTable("garbage\n 20 1 20 Tue Sep  8 12:00:00 2026 S /bin/sh -c long command\n")
    ).toEqual([
      { ...entry(20), startedAt: "Tue Sep 8 12:00:00 2026", command: "/bin/sh -c long command" }
    ])
    expect(sameProcess(entry(20), entry(20))).toBe(true)
    expect(sameProcess(entry(20), entry(20, 1, 20, "second"))).toBe(false)
    expect(sameProcess(entry(20), { ...entry(20), state: "Z+" })).toBe(false)
    expect(sameProcess(undefined, entry(20))).toBe(false)
    expect(sameProcess(entry(20), undefined)).toBe(false)
  })

  it("reads identities without argv and still supports full command snapshots", async () => {
    const compact = await readProcessTable({ includeCommand: false })
    expect(compact.find((entry) => entry.pid === process.pid)).toMatchObject({ command: "" })
    expect(compact.every((entry) => entry.command === "")).toBe(true)
    const full = await readProcessTable()
    expect(full.find((entry) => entry.pid === process.pid)?.command).not.toBe("")
    expect(parseProcessTable("20 1 20 Thu Sep 17 12:00:00 2026 S")).toEqual([
      { ...entry(20), startedAt: "Thu Sep 17 12:00:00 2026", command: "" }
    ])
    expect(parseProcessTable("20 1 20 Thu Sep 17 12:00:00 2026 S echo café 🦊")[0]?.command).toBe(
      "echo café 🦊"
    )
  })

  it("captures descendants regardless of table order, excluding other workspaces", async () => {
    const entries = [entry(32, 31, 30), entry(31, 30, 30), entry(30), entry(90)]
    expect(processTree(entries, [30], false).map((p) => p.pid)).toEqual([32, 31])
    const fake = fakeSystem(entries)
    await stopProcessTree(30, { system: fake.system })
    expect(fake.signals.map(([pid]) => pid).sort()).toEqual([30, 31, 32])
  })

  it("waits for cleanup commands created by a SIGTERM handler", async () => {
    const fake = fakeSystem([entry(30)])
    fake.system.signal = (pid, signal) => {
      fake.signals.push([pid, signal])
      fake.set([entry(30), entry(31, 30, 30)])
    }
    let sleeps = 0
    fake.system.sleep = async () => {
      sleeps++
      if (sleeps === 2) fake.set([])
    }
    await stopProcesses([entry(30)], { system: fake.system })
    expect(sleeps).toBe(2)
    expect(fake.signals).toEqual([[30, "SIGTERM"]])
  })

  it("follows captured children after reparenting and force-kills stubborn survivors", async () => {
    const fake = fakeSystem([entry(30), entry(31, 30, 30)])
    fake.system.signal = (pid, signal) => {
      fake.signals.push([pid, signal])
      fake.set(signal === "SIGKILL" ? [] : [entry(31, 1, 30)])
    }
    await stopProcesses([entry(30), entry(31, 30, 30)], { system: fake.system, graceMs: 100 })
    expect(fake.signals).toEqual([
      [30, "SIGTERM"],
      [31, "SIGTERM"],
      [31, "SIGKILL"]
    ])
  })

  it("checks identities again immediately before signalling", async () => {
    const fake = fakeSystem([entry(30)])
    let reads = 0
    fake.system.list = async () => (++reads === 1 ? [entry(30)] : [entry(30, 1, 30, "reused")])
    await stopProcesses([entry(30)], { system: fake.system })
    expect(fake.signals).toEqual([])
    await stopProcessTree(30, { system: fake.system, identity: entry(30) })
    expect(fake.signals).toEqual([])
  })

  it("ignores already-exited processes and refuses unsafe roots", async () => {
    const fake = fakeSystem([])
    await stopProcesses([], { system: fake.system })
    await stopProcesses([entry(process.pid), entry(1)], { system: fake.system })
    await stopProcessTree(30, { system: fake.system })
    for (const pid of [0, 1, -30, NaN, process.pid])
      await expect(stopProcessTree(pid)).rejects.toThrow("Refusing")
  })

  it("reports permission failures and processes surviving escalation", async () => {
    const fake = fakeSystem([entry(30)])
    fake.system.signal = () => {
      throw Object.assign(new Error("denied"), { code: "EPERM" })
    }
    await expect(stopProcesses([entry(30)], { system: fake.system })).rejects.toThrow("denied")
    fake.system.signal = () => {}
    await expect(
      stopProcesses([entry(30)], { system: fake.system, graceMs: 0, forceMs: 0 })
    ).rejects.toThrow("Processes did not exit: 30")
    fake.system.signal = () => {
      fake.set([])
      throw Object.assign(new Error("gone"), { code: "ESRCH" })
    }
    await stopProcesses([entry(30)], { system: fake.system, graceMs: 0, forceMs: 0 })
  })

  it.each(["tree", "child-first"])("shuts down a real shell tree (%s)", async (order) => {
    const child = spawn(
      process.execPath,
      [
        "-e",
        `
      const {spawn}=require('node:child_process');
      const worker=spawn(process.execPath,['-e', 'process.on("SIGTERM",()=>{console.log("cleaned");process.exit(0)});console.log("ready",process.pid);setInterval(()=>{},1000)'],{stdio:['ignore','pipe','inherit']});
      worker.stdout.pipe(process.stdout);
      let stopping=false;
      let workerExited=false;
      const finish=()=>{if(stopping && workerExited) process.exit(0)};
      worker.once('exit',()=>{workerExited=true;console.log('worker-exited');finish()});
      process.on('SIGTERM',()=>{stopping=true;finish()});
      setInterval(()=>{},1000);
    `
      ],
      { detached: true, stdio: ["ignore", "pipe", "inherit"] }
    )
    let output = ""
    let workerPID = 0
    let acknowledgeWorkerExit: () => void
    const workerExited = new Promise<void>((resolve) => {
      acknowledgeWorkerExit = resolve
    })
    const ready = new Promise<void>((resolve, reject) => {
      child.stdout.on("data", (chunk) => {
        output += chunk
        const match = output.match(/ready (\d+)/)
        if (match) {
          workerPID = Number(match[1])
          resolve()
        }
        if (output.includes("worker-exited")) acknowledgeWorkerExit()
      })
      child.once("exit", () => reject(new Error("Fixture exited before readiness")))
      child.once("error", reject)
    })
    const exited = once(child, "exit")
    const tracking = trackProcessTree(child.pid!, { detached: true })
    const cleanup = async () => {
      if (child.exitCode === null && child.signalCode === null) {
        try {
          process.kill(-child.pid!, "SIGKILL")
        } catch {
          /* Already exited. */
        }
      }
      await exited
      ;(await tracking).dispose()
    }
    onTestFinished(cleanup)
    try {
      const [, tree] = await Promise.all([ready, tracking])
      expect(await processIdentity(child.pid!)).toBeDefined()
      if (order === "child-first") {
        process.kill(workerPID, "SIGTERM")
        await workerExited
      }
      await tree.stop()
      await exited
      expect(output).toContain("cleaned")
      expect(await processIdentity(child.pid!)).toBeUndefined()
      await tree.stop()
    } finally {
      await cleanup()
    }
  })
})
