import { describe, expect, it } from "vitest"
import { makeTerminalManager, TerminalError } from "./index.js"
import { run, FakeProcess, makeSpawner, inputFrame } from "./test-support.js"

describe("@codevisor/terminal terminal manager snapshots", () => {
  it("restores snapshotted terminals as closed scrollback with a synthetic exit", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    const created = await run(
      manager.createTerminal({ sessionId: "session-live", cwd: "/tmp", cols: 80, rows: 24 })
    )
    spawner.handlers[0]?.onOutput("hello ")
    spawner.handlers[0]?.onOutput("world")
    await run(manager.handleClientFrame(created.terminalId, inputFrame(1, "ls\n")))

    const snapshot = manager.snapshotTerminals()
    const restored = makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    restored.restoreTerminals(snapshot)

    // Scrollback replays from the client's cursor, followed by the synthetic
    // exit (the process died with the previous server).
    const frames: Array<{ type: string; seq: number }> = []
    await run(
      restored.connectTerminal(created.terminalId, 1, (frame) => {
        frames.push({ type: frame.type, seq: frame.seq })
      })
    )
    expect(frames).toEqual([
      { type: "output", seq: 2 },
      { type: "exit", seq: 3 }
    ])

    // Input is refused: the restored terminal is closed and process-less.
    await expect(
      run(restored.handleClientFrame(created.terminalId, inputFrame(2, "pwd\n")))
    ).rejects.toBeInstanceOf(TerminalError)

    // The session mapping is NOT reclaimed: the next createTerminal for the
    // session spawns a fresh shell instead of handing back dead scrollback.
    const fresh = await run(
      restored.createTerminal({ sessionId: "session-live", cwd: "/tmp", cols: 80, rows: 24 })
    )
    expect(fresh.terminalId).not.toBe(created.terminalId)
    expect(spawner.requests).toHaveLength(2)
  })

  it("keeps restored external terminals attachable by session", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    const handle = manager.registerExternalTerminal({ sessionId: "agent:bg:1" }, new FakeProcess())
    handle.output("build output")
    handle.exit(0)

    const restored = makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    restored.restoreTerminals(manager.snapshotTerminals())

    // attachOnly still resolves the session to the restored terminal.
    const attached = await run(
      restored.createTerminal({
        sessionId: "agent:bg:1",
        cwd: "/tmp",
        cols: 80,
        rows: 24,
        attachOnly: true
      })
    )
    expect(attached.terminalId).toBe(handle.terminalId)

    // Already-exited externals do not gain a second exit frame, and input
    // frames stay meaningless no-ops rather than errors.
    const frames = await run(restored.terminalFrames(handle.terminalId))
    expect(frames.map((frame) => frame.type)).toEqual(["output", "exit"])
    await run(restored.handleClientFrame(handle.terminalId, inputFrame(1, "ignored")))
  })

  it("restore skips terminal ids that already exist", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    const handle = manager.registerExternalTerminal({ sessionId: "agent:bg:2" }, new FakeProcess())
    handle.output("live")

    const snapshot = manager.snapshotTerminals()
    manager.restoreTerminals(snapshot)

    // The live terminal was not clobbered: it still accepts output.
    handle.output("still live")
    const frames = await run(manager.terminalFrames(handle.terminalId))
    expect(frames.filter((frame) => frame.type === "output")).toHaveLength(2)
    expect(frames.filter((frame) => frame.type === "exit")).toHaveLength(0)
  })
})
