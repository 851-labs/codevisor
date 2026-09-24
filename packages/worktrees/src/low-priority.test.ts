import { describe, expect, it } from "vitest"

import { makePriorityWrapper, systemPriorityHost, withPriority } from "./low-priority.js"

const host = (platform: NodeJS.Platform, executables: ReadonlyArray<string>) => ({
  platform,
  isExecutable: (path: string) => executables.includes(path)
})

describe("low-priority commands", () => {
  it("clamps macOS commands with taskpolicy", () => {
    const wrap = makePriorityWrapper(host("darwin", ["/usr/sbin/taskpolicy"]))
    expect(wrap("git", ["status"], "utility")).toEqual({
      command: "/usr/sbin/taskpolicy",
      args: ["-c", "utility", "git", "status"]
    })
    expect(wrap("/bin/rm", ["-rf", "x"], "background")).toEqual({
      command: "/usr/sbin/taskpolicy",
      args: ["-b", "/bin/rm", "-rf", "x"]
    })
    expect(wrap("git", ["status"])).toEqual({ command: "git", args: ["status"] })
  })

  it("uses nice on Linux, adding the idle I/O class for background work", () => {
    const wrap = makePriorityWrapper(host("linux", ["/bin/nice", "/usr/bin/ionice"]))
    expect(wrap("git", ["gc"], "utility")).toEqual({
      command: "/bin/nice",
      args: ["-n", "10", "git", "gc"]
    })
    expect(wrap("/bin/rm", ["x"], "background")).toEqual({
      command: "/usr/bin/ionice",
      args: ["-c3", "/bin/nice", "-n", "19", "/bin/rm", "x"]
    })
    const withoutIonice = makePriorityWrapper(host("linux", ["/usr/bin/nice"]))
    expect(withoutIonice("/bin/rm", ["x"], "background")).toEqual({
      command: "/usr/bin/nice",
      args: ["-n", "19", "/bin/rm", "x"]
    })
  })

  it("runs commands plainly when no priority tool is available", () => {
    for (const wrap of [
      makePriorityWrapper(host("darwin", [])),
      makePriorityWrapper(host("linux", [])),
      makePriorityWrapper(host("win32", ["/usr/sbin/taskpolicy", "/usr/bin/nice"]))
    ]) {
      expect(wrap("git", ["status"], "background")).toEqual({ command: "git", args: ["status"] })
    }
  })

  it("probes the real machine for executables", () => {
    expect(systemPriorityHost.isExecutable("/bin/sh")).toBe(true)
    expect(systemPriorityHost.isExecutable("/nonexistent/codevisor-tool")).toBe(false)
    const previous = process.env.CODEVISOR_COMMAND_PRIORITY
    delete process.env.CODEVISOR_COMMAND_PRIORITY
    try {
      expect(withPriority("git", ["status"])).toEqual({ command: "git", args: ["status"] })
    } finally {
      process.env.CODEVISOR_COMMAND_PRIORITY = previous
    }
  })

  it("runs at normal priority when the environment asks for it", () => {
    const previous = process.env.CODEVISOR_COMMAND_PRIORITY
    process.env.CODEVISOR_COMMAND_PRIORITY = "normal"
    try {
      expect(withPriority("git", ["status"], "background")).toEqual({
        command: "git",
        args: ["status"]
      })
    } finally {
      process.env.CODEVISOR_COMMAND_PRIORITY = previous
    }
  })
})
