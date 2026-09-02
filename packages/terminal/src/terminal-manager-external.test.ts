import { describe, expect, it } from "vitest"
import { makeTerminalManager, TerminalError } from "./index.js"
import {
  run,
  FakeProcess,
  makeSpawner,
  inputFrame,
  resizeFrame,
  closeFrame
} from "./test-support.js"

describe("@codevisor/terminal terminal manager external terminals", () => {
  it("registers external terminals that stay attachable across exit", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const process = new FakeProcess()

    // Attach-only creation fails until the external terminal is registered.
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

    // Pipe-fed output gets \r\n line endings; existing \r\n stays untouched.
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
    expect(await run(manager.terminalFrames(handle.terminalId))).toEqual([
      { type: "output", seq: 1, data: "line1\r\nline2\r\nline3\r\n" }
    ])

    // Client input/resize forward to the caller's process; close kills it.
    await run(manager.handleClientFrame(handle.terminalId, inputFrame(1, "q")))
    await run(manager.handleClientFrame(handle.terminalId, resizeFrame(2, 100, 30)))
    expect(process.writes).toEqual(["q"])
    expect(process.resizes).toEqual([[100, 30]])

    // Exit is idempotent, keeps the terminal attachable, and never respawns.
    handle.exit(3)
    handle.exit(9)
    handle.output("late")
    const reattached = await run(
      manager.createTerminal({ sessionId: "bg-key-1", cwd: "/tmp", cols: 80, rows: 24 })
    )
    expect(reattached.terminalId).toBe(handle.terminalId)
    const frames = await run(manager.terminalFrames(handle.terminalId, 1))
    expect(frames[0]).toEqual({ type: "exit", seq: 2, exitCode: 3 })
    expect(spawner.requests).toHaveLength(0)

    // Frames to an exited external terminal are ignored, not errors.
    await run(manager.handleClientFrame(handle.terminalId, inputFrame(3, "ignored")))
    expect(process.writes).toEqual(["q"])

    // An explicit session close finally removes the exited terminal.
    expect(await run(manager.closeTerminalForSession("bg-key-1"))).toBe(false)
    await expect(run(manager.terminalFrames(handle.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
  })

  it("kills live external terminals on close frames and session closes", async () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    const first = new FakeProcess()
    const firstHandle = manager.registerExternalTerminal({ sessionId: "bg-key-2" }, first)
    await run(manager.handleClientFrame(firstHandle.terminalId, closeFrame(1)))
    expect(first.killCount).toBe(1)

    // Raw output (no normalization) passes through byte-for-byte.
    const second = new FakeProcess()
    const secondHandle = manager.registerExternalTerminal({ sessionId: "bg-key-2" }, second)
    secondHandle.output("raw\nbytes")
    expect(await run(manager.terminalFrames(secondHandle.terminalId))).toEqual([
      { type: "output", seq: 1, data: "raw\nbytes" }
    ])
    // The session key now resolves to the replacement terminal.
    expect(
      (await run(manager.createTerminal({ sessionId: "bg-key-2", cwd: "/", cols: 1, rows: 1 })))
        .terminalId
    ).toBe(secondHandle.terminalId)

    expect(await run(manager.closeTerminalForSession("bg-key-2"))).toBe(true)
    expect(second.killCount).toBe(1)

    // remove() drops a never-surfaced terminal entirely.
    const third = manager.registerExternalTerminal({ sessionId: "bg-key-3" }, new FakeProcess())
    third.remove()
    await expect(run(manager.terminalFrames(third.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
    expect(await run(manager.closeTerminalForSession("bg-key-3"))).toBe(false)
  })

  it("replaces a still-registered external terminal on re-registration", async () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    const first = manager.registerExternalTerminal({ sessionId: "bg-key-5" }, new FakeProcess())
    // A signal-terminated process reports an exit frame without a code.
    first.exit()
    expect(await run(manager.terminalFrames(first.terminalId))).toEqual([{ type: "exit", seq: 1 }])
    const replacement = manager.registerExternalTerminal(
      { sessionId: "bg-key-5" },
      new FakeProcess()
    )
    await expect(run(manager.terminalFrames(first.terminalId))).rejects.toBeInstanceOf(
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
    // Live processes are killed; exited ones just lose their scrollback.
    expect(runningProcess.killCount).toBe(1)
    await expect(run(manager.terminalFrames(running.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
    await expect(run(manager.terminalFrames(exited.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
    // Other sessions' terminals are untouched, and a second sweep finds nothing.
    expect(await run(manager.terminalFrames(unrelated.terminalId))).toEqual([])
    expect(await run(manager.closeTerminalsForSessionPrefix("agent-1:bg:"))).toBe(0)
  })

  it("caps the replay buffer of external terminals", async () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    const handle = manager.registerExternalTerminal({ sessionId: "bg-key-4" }, new FakeProcess())
    for (let index = 0; index < 20_001; index += 1) {
      handle.output(`chunk-${index}`)
    }
    const frames = await run(manager.terminalFrames(handle.terminalId))
    expect(frames).toHaveLength(20_000)
    expect(frames[0]).toEqual({ type: "output", seq: 2, data: "chunk-1" })
  })

  it("wraps non-Error process failures as terminal errors", async () => {
    const spawner = makeSpawner((_request, handlers) => {
      handlers.onOutput("boot")
    })
    const manager = makeTerminalManager({ spawner })
    const terminal = await run(
      manager.createTerminal({
        sessionId: "session-4",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )
    const cause: unknown = { reason: "sink failure" }

    await expect(
      run(
        manager.connectTerminal(terminal.terminalId, 0, () => {
          throw cause
        })
      )
    ).rejects.toBeInstanceOf(TerminalError)
  })
})
