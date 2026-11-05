import { ChildProcess } from "node:child_process"

import { afterEach, describe, expect, it, vi } from "vitest"

import {
  ActiveWorkSleepInhibitor,
  makeActiveWorkSleepInhibitor
} from "./active-work-sleep-inhibitor.js"

const spawnMock = vi.hoisted(() => vi.fn())
vi.mock("node:child_process", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:child_process")>()),
  spawn: spawnMock
}))

class FakeCaffeinateProcess extends ChildProcess {
  kills = 0

  override kill(): boolean {
    this.kills += 1
    this.emit("exit", 0, null)
    return true
  }
}

afterEach(() => {
  spawnMock.mockReset()
})

describe("ActiveWorkSleepInhibitor", () => {
  it("holds one assertion until every active session settles", () => {
    const children: FakeCaffeinateProcess[] = []
    const inhibitor = new ActiveWorkSleepInhibitor(() => {
      const child = new FakeCaffeinateProcess()
      children.push(child)
      return child
    }, vi.fn())

    inhibitor.update("session-a", true)
    inhibitor.update("session-a", true)
    inhibitor.update("session-b", true)
    expect(children).toHaveLength(1)

    inhibitor.update("session-a", false)
    expect(children[0]?.kills).toBe(0)
    inhibitor.update("session-b", false)
    expect(children[0]?.kills).toBe(1)

    inhibitor.update("session-c", true)
    expect(children).toHaveLength(2)
    inhibitor.stop()
    expect(children[1]?.kills).toBe(1)
  })

  it("is disabled away from macOS", () => {
    expect(makeActiveWorkSleepInhibitor("linux")).toBeUndefined()
  })

  it.each([new Error("caffeinate unavailable"), "caffeinate unavailable"])(
    "keeps assertion failures from disrupting session events (%s)",
    (cause) => {
      const log = vi.fn()
      const inhibitor = new ActiveWorkSleepInhibitor(() => {
        throw cause
      }, log)

      inhibitor.update("session-a", true)
      expect(log).toHaveBeenCalledWith("Active-work sleep assertion failed: caffeinate unavailable")
    }
  )

  it("handles child errors, stale callbacks, and natural exits", () => {
    const children: FakeCaffeinateProcess[] = []
    const log = vi.fn()
    const inhibitor = new ActiveWorkSleepInhibitor(() => {
      const child = new FakeCaffeinateProcess()
      children.push(child)
      return child
    }, log)

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
      const child = new ChildProcess()
      vi.spyOn(child, "kill").mockImplementation(() => {
        throw cause
      })
      const inhibitor = new ActiveWorkSleepInhibitor(() => child, log)

      inhibitor.update("session-a", true)
      inhibitor.update("session-a", false)
      expect(log).toHaveBeenCalledWith("Active-work sleep assertion cleanup failed: cleanup failed")
    }
  })

  it("holds caffeinate on this process and logs to the console on macOS", () => {
    const child = new FakeCaffeinateProcess()
    spawnMock.mockReturnValue(child)
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {})
    const inhibitor = makeActiveWorkSleepInhibitor("darwin")
    try {
      inhibitor?.update("session-a", true)
      expect(spawnMock).toHaveBeenCalledWith(
        "/usr/bin/caffeinate",
        ["-i", "-w", String(process.pid)],
        { stdio: "ignore" }
      )
      child.emit("error", "default logger")
      expect(consoleError).toHaveBeenCalledWith(
        "Active-work sleep assertion failed: default logger"
      )
    } finally {
      inhibitor?.stop()
      consoleError.mockRestore()
    }
  })

  it("follows the host platform by default", () => {
    const inhibitor = makeActiveWorkSleepInhibitor()
    expect(inhibitor === undefined).toBe(process.platform !== "darwin")
    inhibitor?.stop()
  })
})
