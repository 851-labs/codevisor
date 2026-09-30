import { EventEmitter } from "node:events"

import { describe, expect, it } from "vitest"

import {
  installProcessSafetyNet,
  UNCAUGHT_EXCEPTION_BUDGET,
  UNCAUGHT_EXCEPTION_WINDOW_MS
} from "./process-safety-net.js"

const install = () => {
  const target = new EventEmitter()
  const lines: string[] = []
  const exits: number[] = []
  let clock = 0
  installProcessSafetyNet(target, {
    log: (line) => lines.push(line),
    exit: (code) => exits.push(code),
    now: () => clock
  })
  return {
    lines,
    exits,
    advance: (ms: number) => {
      clock += ms
    },
    throwUncaught: (message = "tunnel stream is closed") =>
      target.emit("uncaughtException", new Error(message), "uncaughtException"),
    reject: (reason: unknown) => target.emit("unhandledRejection", reason)
  }
}

describe("installProcessSafetyNet", () => {
  it("logs an unhandled rejection with its stack and keeps the server running", () => {
    const net = install()
    net.reject(new Error("tunnel stream is closed"))
    net.reject("plain reason")
    const stackless = new TypeError("no stack")
    delete stackless.stack
    net.reject(stackless)
    expect(net.exits).toEqual([])
    expect(net.lines[0]).toMatch(/unhandled rejection.*Error: tunnel stream is closed\n\s+at /s)
    expect(net.lines[1]).toContain("plain reason")
    expect(net.lines[2]).toContain("TypeError: no stack")
  })

  it("survives isolated uncaught exceptions", () => {
    const net = install()
    for (let index = 0; index < UNCAUGHT_EXCEPTION_BUDGET * 3; index += 1) {
      net.throwUncaught()
      // Spread out: never more than one inside any window.
      net.advance(UNCAUGHT_EXCEPTION_WINDOW_MS)
    }
    expect(net.exits).toEqual([])
    expect(net.lines).toHaveLength(UNCAUGHT_EXCEPTION_BUDGET * 3)
    expect(net.lines[0]).toMatch(/uncaught exception \(uncaughtException; server kept running\)/)
  })

  it("exits once a burst of uncaught exceptions exceeds the budget", () => {
    const net = install()
    for (let index = 0; index < UNCAUGHT_EXCEPTION_BUDGET; index += 1) net.throwUncaught()
    expect(net.exits).toEqual([])
    // One past the budget inside the same window: something is spinning.
    net.advance(UNCAUGHT_EXCEPTION_WINDOW_MS - 1)
    net.throwUncaught("still broken")
    expect(net.exits).toEqual([1])
    expect(net.lines.at(-1)).toMatch(/uncaught exceptions within 60s; exiting: Error: still broken/)
  })
})
