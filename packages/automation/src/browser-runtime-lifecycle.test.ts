import { ChildProcess } from "node:child_process"

import { afterEach, expect, it, vi } from "vitest"

import { closeBrowserRuntime, waitForTargetsClosed } from "./browser-runtime-lifecycle.js"
import { fakeBrowserRuntime, fakeCdpConnection } from "./browser-runtime-test-support.js"

function fixture(owned = true) {
  const requested = Promise.withResolvers<void>()
  const processHandle = new ChildProcess()
  const kill = vi.spyOn(processHandle, "kill").mockReturnValue(true)
  const connection = {
    send: vi.fn(async () => {
      requested.resolve()
      return {}
    }),
    close: vi.fn(async () => undefined)
  }
  const active = fakeBrowserRuntime({
    owned,
    processHandle,
    connection: fakeCdpConnection(connection).connection
  })
  const exit = (signal: NodeJS.Signals | null = null) => {
    const exitCode = signal === null ? 0 : null
    Object.assign(processHandle, { signalCode: signal, exitCode })
    processHandle.emit("exit", exitCode, signal)
  }
  return { active, connection, processHandle, kill, requested: requested.promise, exit }
}

afterEach(() => vi.useRealTimers())

it("waits for confirmed process exit even after the termination grace periods expire", async () => {
  vi.useFakeTimers()
  const { active, connection, processHandle, kill, requested, exit } = fixture()
  const closing = closeBrowserRuntime(active)
  await requested
  await vi.advanceTimersByTimeAsync(499)
  expect(kill).not.toHaveBeenCalled()
  expect(connection.close).not.toHaveBeenCalled()
  await vi.advanceTimersByTimeAsync(1)
  expect(kill).toHaveBeenCalledExactlyOnceWith("SIGTERM")
  expect(connection.close).not.toHaveBeenCalled()
  await vi.advanceTimersByTimeAsync(1_499)
  expect(kill).toHaveBeenCalledExactlyOnceWith("SIGTERM")
  await vi.advanceTimersByTimeAsync(1)
  expect(kill.mock.calls).toEqual([["SIGTERM"], ["SIGKILL"]])
  expect(connection.close).not.toHaveBeenCalled()
  exit("SIGKILL")
  await closing
  expect(connection.close).toHaveBeenCalledOnce()
  expect(processHandle.listenerCount("exit")).toBe(0)
  expect(vi.getTimerCount()).toBe(0)
})

it("observes an exit that arrives before Browser.close replies and cancels escalation", async () => {
  vi.useFakeTimers()
  const { active, connection, kill, exit } = fixture()
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
  expect(kill).not.toHaveBeenCalled()
  expect(vi.getTimerCount()).toBe(0)
})

it("recognizes a process that already exited from a signal", async () => {
  vi.useFakeTimers()
  const { active, connection, processHandle, kill, exit } = fixture()
  exit("SIGTERM")
  await closeBrowserRuntime(active)
  expect(connection.close).toHaveBeenCalledOnce()
  expect(kill).not.toHaveBeenCalled()
  expect(processHandle.listenerCount("exit")).toBe(0)
  expect(vi.getTimerCount()).toBe(0)
})

it("only disconnects from a browser it does not own", async () => {
  const { active, connection, kill } = fixture(false)
  await closeBrowserRuntime(active)
  expect(connection.send).not.toHaveBeenCalled()
  expect(kill).not.toHaveBeenCalled()
  expect(connection.close).toHaveBeenCalledOnce()
})

it("waits until closed tabs stop being listed, and no longer than the deadline", async () => {
  const replies: Array<unknown> = [
    { targetInfos: [{ targetId: "popup" }, { targetId: "other" }] },
    { targetInfos: [{ targetId: "other" }] }
  ]
  const send = vi.fn(async () => replies.shift())
  const active = fakeBrowserRuntime({ connection: fakeCdpConnection({ send }).connection })

  await waitForTargetsClosed(active, [])
  expect(send).not.toHaveBeenCalled()
  await waitForTargetsClosed(active, ["popup"], 2_000, 1)
  expect(send).toHaveBeenCalledTimes(2)

  send.mockImplementation(async () => ({ targetInfos: [{ targetId: "stuck" }] }))
  await waitForTargetsClosed(active, ["stuck"], 0)
  expect(send).toHaveBeenCalledTimes(3)

  send.mockImplementation(async () => {
    throw new Error("closed")
  })
  await waitForTargetsClosed(active, ["popup"])
  send.mockImplementation(async () => ({}))
  await waitForTargetsClosed(active, ["popup"])
  expect(send).toHaveBeenCalledTimes(5)
})
