import { describe, expect, it } from "vitest"

import { makeTerminalManager, TerminalError } from "./index.js"
import {
  run,
  FakeProcess,
  makeSpawner,
  inputFrame,
  resizeFrame,
  closeFrame,
  replayedFrames
} from "./test-support.js"

describe("@codevisor/terminal terminal manager external terminals", () => {
  it("registers external terminals that stay attachable across exit", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const process = new FakeProcess()

    await expect(
      run(
        manager.createTerminal({
          sessionId: "bg-key-1",
          cwd: "/tmp",
          cols: 80,
          rows: 24,
          attachOnly: true
        })
      )
    ).rejects.toBeInstanceOf(TerminalError)

    const handle = manager.registerExternalTerminal(
      { sessionId: "bg-key-1", normalizeNewlines: true },
      process
    )
    expect(handle.response.websocketPath).toBe(`/v1/terminals/${handle.terminalId}/socket`)

    handle.output("line1\nline2\r\nline3\n")
    const attached = await run(
      manager.createTerminal({
        sessionId: "bg-key-1",
        cwd: "/tmp",
        cols: 80,
        rows: 24,
        attachOnly: true
      })
    )
    expect(attached.terminalId).toBe(handle.terminalId)
    expect(await run(replayedFrames(manager, handle.terminalId))).toEqual([
      { type: "output", seq: 1, data: "line1\r\nline2\r\nline3\r\n" }
    ])

    await run(manager.handleClientFrame(handle.terminalId, inputFrame(1, "q")))
    await run(manager.handleClientFrame(handle.terminalId, resizeFrame(2, 100, 30)))
    expect(process.writes).toEqual(["q"])
    expect(process.resizes).toEqual([[100, 30]])

    handle.exit(3)
    handle.exit(9)
    handle.output("late")
    const reattached = await run(
      manager.createTerminal({ sessionId: "bg-key-1", cwd: "/tmp", cols: 80, rows: 24 })
    )
    expect(reattached.terminalId).toBe(handle.terminalId)
    const frames = await run(replayedFrames(manager, handle.terminalId, 1))
    expect(frames[0]).toEqual({ type: "exit", seq: 2, exitCode: 3 })
    expect(spawner.requests).toHaveLength(0)

    await run(manager.handleClientFrame(handle.terminalId, inputFrame(3, "ignored")))
    expect(process.writes).toEqual(["q"])

    expect(await run(manager.closeTerminalForSession("bg-key-1"))).toBe(false)
    await expect(run(replayedFrames(manager, handle.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
  })

  it("kills live external terminals on close frames and session closes", async () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    const first = new FakeProcess()
    const firstHandle = manager.registerExternalTerminal({ sessionId: "bg-key-2" }, first)
    await run(manager.handleClientFrame(firstHandle.terminalId, closeFrame(1)))
    expect(first.killCount).toBe(1)

    const second = new FakeProcess()
    const secondHandle = manager.registerExternalTerminal({ sessionId: "bg-key-2" }, second)
    secondHandle.output("raw\nbytes")
    expect(await run(replayedFrames(manager, secondHandle.terminalId))).toEqual([
      { type: "output", seq: 1, data: "raw\nbytes" }
    ])
    expect(
      (await run(manager.createTerminal({ sessionId: "bg-key-2", cwd: "/", cols: 1, rows: 1 })))
        .terminalId
    ).toBe(secondHandle.terminalId)

    expect(await run(manager.closeTerminalForSession("bg-key-2"))).toBe(true)
    expect(second.killCount).toBe(1)

    const third = manager.registerExternalTerminal({ sessionId: "bg-key-3" }, new FakeProcess())
    third.remove()
    await expect(run(replayedFrames(manager, third.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
    expect(await run(manager.closeTerminalForSession("bg-key-3"))).toBe(false)
  })

  it("replaces a still-registered external terminal on re-registration", async () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    const first = manager.registerExternalTerminal({ sessionId: "bg-key-5" }, new FakeProcess())
    first.exit()
    expect(await run(replayedFrames(manager, first.terminalId))).toEqual([{ type: "exit", seq: 1 }])
    const replacement = manager.registerExternalTerminal(
      { sessionId: "bg-key-5" },
      new FakeProcess()
    )
    await expect(run(replayedFrames(manager, first.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
    expect(
      (await run(manager.createTerminal({ sessionId: "bg-key-5", cwd: "/", cols: 1, rows: 1 })))
        .terminalId
    ).toBe(replacement.terminalId)
  })

  it("closes every terminal under a session-key prefix", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })

    const runningProcess = new FakeProcess()
    const running = manager.registerExternalTerminal(
      { sessionId: "agent-1:bg:tool-1" },
      runningProcess
    )
    const exited = manager.registerExternalTerminal(
      { sessionId: "agent-1:bg:tool-2" },
      new FakeProcess()
    )
    exited.exit(0)
    const unrelated = manager.registerExternalTerminal(
      { sessionId: "agent-2:bg:tool-1" },
      new FakeProcess()
    )

    expect(await run(manager.closeTerminalsForSessionPrefix("agent-1:bg:"))).toBe(2)
    expect(runningProcess.killCount).toBe(1)
    await expect(run(replayedFrames(manager, running.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
    await expect(run(replayedFrames(manager, exited.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
    expect(await run(replayedFrames(manager, unrelated.terminalId))).toEqual([])
    expect(await run(manager.closeTerminalsForSessionPrefix("agent-1:bg:"))).toBe(0)
  })

  it("bounds the replay buffer by bytes and resyncs clients it no longer reaches", async () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    const handle = manager.registerExternalTerminal({ sessionId: "bg-key-4" }, new FakeProcess())
    const chunk = "x".repeat(64 * 1024)
    for (let index = 0; index < 40; index += 1) {
      handle.output(chunk)
    }
    const recent = await run(replayedFrames(manager, handle.terminalId, 20))
    expect(recent.map((frame) => frame.seq)).toEqual(Array.from({ length: 20 }, (_, i) => i + 21))
    const [resync, ...rest] = await run(replayedFrames(manager, handle.terminalId))
    expect(rest).toEqual([])
    expect(resync).toMatchObject({ type: "output", seq: 40, reset: true })
    expect(resync?.type === "output" && resync.data.startsWith("\u001bc")).toBe(true)
  })
})
