import { existsSync, mkdtempSync, readFileSync, rmSync, watch } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { type Ended, SupervisedProcesses } from "./supervised-processes.js"

const isAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

const written = (path: string): Promise<string> =>
  new Promise((resolve) => {
    const read = () => {
      if (!existsSync(path) || readFileSync(path, "utf8").trim() === "") return
      watcher.close()
      resolve(readFileSync(path, "utf8").trim())
    }
    const watcher = watch(dirname(path), read)
    read()
  })

describe("the processes a desktop is made of", () => {
  it("are stopped together with what they started, and stopping waits until they are gone", async () => {
    const processes = new SupervisedProcesses(() => undefined)
    const folder = mkdtempSync(join(tmpdir(), "cv-run-"))
    onTestFinished(() => rmSync(folder, { recursive: true, force: true }))
    const pidFile = join(folder, "helper.pid")
    const session = processes.start("sh", ["-c", 'sleep 300 & echo $! > "$PID_FILE"; wait'], {
      PID_FILE: pidFile
    })
    const helper = Number(await written(pidFile))
    expect(isAlive(helper)).toBe(true)

    await processes.stop()
    expect(session.exitCode !== null || session.signalCode !== null).toBe(true)
    expect(isAlive(helper)).toBe(false)
  })

  it("report the one that ends by itself, and say nothing about those it stops", async () => {
    const ends: Ended[] = []
    const ended = Promise.withResolvers<void>()
    const processes = new SupervisedProcesses((end) => {
      ends.push(end)
      ended.resolve()
    })
    processes.start("sleep", ["300"], {})
    processes.start("sh", ["-c", "exit 3"], {})
    await ended.promise
    await processes.stop()
    expect(ends).toEqual([{ program: "sh", reason: "stopped (exit 3)" }])
  })

  it("report a program that isn't installed", async () => {
    const ended = Promise.withResolvers<Ended>()
    const processes = new SupervisedProcesses((end) => ended.resolve(end))
    processes.start("no-such-desktop-program", [], {})
    expect(await ended.promise).toMatchObject({
      program: "no-such-desktop-program",
      reason: expect.stringContaining("couldn't start")
    })
    await processes.stop()
  })
})
