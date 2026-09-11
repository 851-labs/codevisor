import { EventEmitter } from "node:events"
import type { ChildProcess } from "node:child_process"
import { afterEach, expect, it, vi } from "vitest"
import type { BrowserRuntime } from "./browser-cdp-engine.js"
import { closeBrowserRuntime } from "./browser-runtime-lifecycle.js"

function fixture(owned = true) {
  const requested = Promise.withResolvers<void>()
  const processHandle = Object.assign(new EventEmitter(), {
    exitCode: null as number | null,
    signalCode: null as NodeJS.Signals | null,
    kill: vi.fn(() => true)
  })
  const connection = {
    send: vi.fn(async () => {
      requested.resolve()
      return {}
    }),
    close: vi.fn(async () => undefined)
  }
  const active = {
    queue: Promise.resolve(),
    eventDisposers: [],
    owned,
    processHandle: processHandle as unknown as ChildProcess,
    connection
  } as unknown as BrowserRuntime
  const exit = (signal: NodeJS.Signals | null = null) => {
    processHandle.signalCode = signal
    processHandle.exitCode = signal === null ? 0 : null
    processHandle.emit("exit", processHandle.exitCode, signal)
  }
  return { active, connection, processHandle, requested: requested.promise, exit }
}

afterEach(() => vi.useRealTimers())

it("waits for confirmed process exit even after the termination grace periods expire", async () => {
  vi.useFakeTimers()
  const { active, connection, processHandle, requested, exit } = fixture()
  const closing = closeBrowserRuntime(active)
  await requested
  await vi.advanceTimersByTimeAsync(499)
  expect(processHandle.kill).not.toHaveBeenCalled()
  expect(connection.close).not.toHaveBeenCalled()
  await vi.advanceTimersByTimeAsync(1)
  expect(processHandle.kill).toHaveBeenCalledExactlyOnceWith("SIGTERM")
  expect(connection.close).not.toHaveBeenCalled()
  await vi.advanceTimersByTimeAsync(1_499)
  expect(processHandle.kill).toHaveBeenCalledExactlyOnceWith("SIGTERM")
  await vi.advanceTimersByTimeAsync(1)
  expect(processHandle.kill.mock.calls).toEqual([["SIGTERM"], ["SIGKILL"]])
  expect(connection.close).not.toHaveBeenCalled()
  exit("SIGKILL")
  await closing
  expect(connection.close).toHaveBeenCalledOnce()
  expect(processHandle.listenerCount("exit")).toBe(0)
  expect(vi.getTimerCount()).toBe(0)
})

it("observes an exit that arrives before Browser.close replies and cancels escalation", async () => {
  vi.useFakeTimers()
  const { active, connection, processHandle, exit } = fixture()
  const reply = Promise.withResolvers<Record<string, unknown>>()
  connection.send.mockImplementation(() => {
    exit()
    return reply.promise
  })
  connection.close.mockImplementation(async () => {
    reply.resolve({})
  })
  await closeBrowserRuntime(active)
  expect(connection.close).toHaveBeenCalledOnce()
  expect(processHandle.kill).not.toHaveBeenCalled()
  expect(vi.getTimerCount()).toBe(0)
})

it("recognizes a process that already exited from a signal", async () => {
  vi.useFakeTimers()
  const { active, connection, processHandle, exit } = fixture()
  exit("SIGTERM")
  await closeBrowserRuntime(active)
  expect(connection.close).toHaveBeenCalledOnce()
  expect(processHandle.kill).not.toHaveBeenCalled()
  expect(processHandle.listenerCount("exit")).toBe(0)
  expect(vi.getTimerCount()).toBe(0)
})

it("only disconnects from a browser it does not own", async () => {
  const { active, connection, processHandle } = fixture(false)
  await closeBrowserRuntime(active)
  expect(connection.send).not.toHaveBeenCalled()
  expect(processHandle.kill).not.toHaveBeenCalled()
  expect(connection.close).toHaveBeenCalledOnce()
})
