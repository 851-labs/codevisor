import { describe, expect, it, vi } from "vitest"

import { makeTerminalManager, TerminalError } from "./index.js"
import { run } from "./test-support.js"

describe("terminal shutdown", () => {
  it("normalizes failures while replaying a terminal to a disconnected client", async () => {
    for (const failure of [new Error("disconnected"), "disconnected"]) {
      const manager = makeTerminalManager()
      const terminal = manager.registerExternalTerminal(
        { sessionId: "replay" },
        { kill: () => {}, write: () => {}, resize: () => {} }
      )
      terminal.output("buffered")
      await expect(
        run(
          manager.connectTerminal(terminal.terminalId, 0, () => {
            throw failure
          })
        )
      ).rejects.toThrow("disconnected")
    }
  })
  it("awaits cleanup, deduplicates concurrent closes, and blocks restart while stopping", async () => {
    const manager = makeTerminalManager()
    const started = Promise.withResolvers<void>()
    const cleanup = Promise.withResolvers<void>()
    const stop = vi.fn(async () => {
      started.resolve()
      await cleanup.promise
    })
    const terminal = manager.registerExternalTerminal(
      { sessionId: "Chat:Pane" },
      { stop, kill: vi.fn(), write: vi.fn(), resize: vi.fn() }
    )
    const first = run(manager.closeTerminalForSession("chat:pane"))
    await started.promise
    let finished = false
    const second = run(manager.closeTerminalsForSessionPrefix("chat:")).then(() => {
      finished = true
    })
    await expect(
      run(manager.createTerminal({ sessionId: "Chat:Pane", cwd: "/tmp", cols: 80, rows: 24 }))
    ).rejects.toThrow("stopping")
    expect(finished).toBe(false)
    cleanup.resolve()
    expect(await first).toBe(true)
    await second
    expect(stop).toHaveBeenCalledOnce()
    expect(await run(manager.closeTerminalForSession("Chat:Pane"))).toBe(false)
    expect(manager.snapshotTerminals().terminals).toEqual([])
    terminal.exit()
  })

  it("attempts every terminal and retains failed cleanup for retry", async () => {
    const manager = makeTerminalManager()
    const stop = vi
      .fn()
      .mockRejectedValueOnce(new Error("cleanup failed"))
      .mockResolvedValue(undefined)
    manager.registerExternalTerminal(
      { sessionId: "chat:a" },
      { stop, kill: vi.fn(), write: vi.fn(), resize: vi.fn() }
    )
    const second = vi.fn(async () => {})
    const terminal = manager.registerExternalTerminal(
      { sessionId: "chat:b" },
      { stop: second, kill: vi.fn(), write: vi.fn(), resize: vi.fn() }
    )
    terminal.exit()
    await expect(run(manager.closeTerminalsForSessionPrefix("chat:"))).rejects.toThrow(
      "cleanup failed"
    )
    expect(second).toHaveBeenCalledOnce()
    expect(await run(manager.closeTerminalsForSessionPrefix("chat:"))).toBe(1)
    expect(stop).toHaveBeenCalledTimes(2)
  })

  it("cleans descendants of an exited terminal and preserves typed failures", async () => {
    const manager = makeTerminalManager()
    const stop = vi.fn(async () => {})
    const terminal = manager.registerExternalTerminal(
      { sessionId: "exited" },
      { stop, kill: vi.fn(), write: vi.fn(), resize: vi.fn() }
    )
    terminal.exit()
    expect(await run(manager.closeTerminalForSession("exited"))).toBe(false)
    expect(stop).toHaveBeenCalledOnce()
    await expect(run(manager.closeTerminal("missing"))).rejects.toBeInstanceOf(TerminalError)
    manager.registerExternalTerminal(
      { sessionId: "broken" },
      {
        stop: async () => {
          throw "failure"
        },
        kill: vi.fn(),
        write: vi.fn(),
        resize: vi.fn()
      }
    )
    await expect(run(manager.closeTerminalForSession("broken"))).rejects.toThrow("failure")
  })
})
