import { EventEmitter } from "node:events"
import type { ChildProcess } from "node:child_process"
import { describe, expect, it, vi } from "vitest"
import {
  ActiveWorkSleepInhibitor,
  makeActiveWorkSleepInhibitor
} from "./active-work-sleep-inhibitor.js"

const spawnMock = vi.hoisted(() => vi.fn())
vi.mock("node:child_process", () => ({ spawn: spawnMock }))

class FakeCaffeinateProcess extends EventEmitter {
  readonly kill = vi.fn(() => {
    this.emit("exit", 0, null)
    return true
  })
}

describe("ActiveWorkSleepInhibitor", () => {
  it("holds one assertion until every active session settles", () => {
    const children: FakeCaffeinateProcess[] = []
    const inhibitor = new ActiveWorkSleepInhibitor(
      123,
      () => {
        const child = new FakeCaffeinateProcess()
        children.push(child)
        return child as unknown as ChildProcess
      },
      vi.fn()
    )

    inhibitor.update("session-a", true)
    inhibitor.update("session-a", true)
    inhibitor.update("session-b", true)
    expect(children).toHaveLength(1)

    inhibitor.update("session-a", false)
    expect(children[0]?.kill).not.toHaveBeenCalled()
    inhibitor.update("session-b", false)
    expect(children[0]?.kill).toHaveBeenCalledOnce()

    inhibitor.update("session-c", true)
    expect(children).toHaveLength(2)
    inhibitor.stop()
    expect(children[1]?.kill).toHaveBeenCalledOnce()
  })

  it("is disabled away from macOS", () => {
    expect(makeActiveWorkSleepInhibitor({ platform: "linux" })).toBeUndefined()
  })

  it("keeps assertion failures from disrupting session events", () => {
    const log = vi.fn()
    const inhibitor = new ActiveWorkSleepInhibitor(
      123,
      () => {
        throw new Error("caffeinate unavailable")
      },
      log
    )

    expect(() => inhibitor.update("session-a", true)).not.toThrow()
    expect(log).toHaveBeenCalledWith("Active-work sleep assertion failed: caffeinate unavailable")
  })

  it("handles child errors, stale callbacks, and natural exits", () => {
    const children: FakeCaffeinateProcess[] = []
    const log = vi.fn()
    const inhibitor = new ActiveWorkSleepInhibitor(
      123,
      () => {
        const child = new FakeCaffeinateProcess()
        children.push(child)
        return child as unknown as ChildProcess
      },
      log
    )

    inhibitor.update("session-a", true)
    children[0]?.emit("error", new Error("connection lost"))
    expect(log).toHaveBeenCalledWith("Active-work sleep assertion failed: connection lost")

    inhibitor.update("session-b", true)
    children[1]?.emit("error", "terminated")
    expect(log).toHaveBeenCalledWith("Active-work sleep assertion failed: terminated")

    inhibitor.update("session-c", true)
    children[2]?.emit("exit", 0, null)
    inhibitor.update("session-d", true)
    expect(children).toHaveLength(4)

    inhibitor.stop()
    children[3]?.emit("error", new Error("late error"))
    expect(log).not.toHaveBeenCalledWith("Active-work sleep assertion failed: late error")
  })

  it("logs cleanup failures without disrupting session events", () => {
    for (const cause of [new Error("cleanup failed"), "cleanup failed"] as const) {
      const log = vi.fn()
      const child = new EventEmitter() as EventEmitter & { kill: () => boolean }
      child.kill = vi.fn(() => {
        throw cause
      })
      const inhibitor = new ActiveWorkSleepInhibitor(
        123,
        () => child as unknown as ChildProcess,
        log
      )

      inhibitor.update("session-a", true)
      expect(() => inhibitor.update("session-a", false)).not.toThrow()
      expect(log).toHaveBeenCalledWith("Active-work sleep assertion cleanup failed: cleanup failed")
    }
  })

  it("supports both explicit and default macOS dependencies", () => {
    const explicitChild = new FakeCaffeinateProcess()
    const explicitSpawn = vi.fn(() => explicitChild as unknown as ChildProcess)
    const explicit = makeActiveWorkSleepInhibitor({
      platform: "darwin",
      processId: 456,
      spawnCaffeinate: explicitSpawn,
      log: vi.fn()
    })
    explicit?.update("session-a", true)
    expect(explicitSpawn).toHaveBeenCalledWith(456)
    explicit?.stop()

    spawnMock.mockReset()
    const fallbackChild = new FakeCaffeinateProcess()
    spawnMock.mockReturnValue(fallbackChild as unknown as ChildProcess)
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {})
    const fallback = makeActiveWorkSleepInhibitor({ platform: "darwin" })
    expect(fallback).toBeDefined()
    fallback?.update("session-b", true)
    expect(spawnMock).toHaveBeenCalledWith(
      "/usr/bin/caffeinate",
      ["-i", "-w", String(process.pid)],
      { stdio: "ignore" }
    )
    fallbackChild.emit("error", "default logger")
    expect(consoleError).toHaveBeenCalledWith("Active-work sleep assertion failed: default logger")
    fallback?.stop()
    consoleError.mockRestore()

    // Covers the no-argument platform default on every host; the explicit
    // Darwin case above exercises the implementation independently of CI OS.
    makeActiveWorkSleepInhibitor()?.stop()
  })

  it("formats non-Error spawn failures", () => {
    const log = vi.fn()
    const inhibitor = new ActiveWorkSleepInhibitor(
      123,
      () => {
        throw "caffeinate unavailable"
      },
      log
    )

    inhibitor.update("session-a", true)
    expect(log).toHaveBeenCalledWith("Active-work sleep assertion failed: caffeinate unavailable")
  })
})
