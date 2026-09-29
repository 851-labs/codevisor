import type { TerminalServerFrame } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeTerminalManager, TerminalError } from "./index.js"
import { run, FakeProcess, makeSpawner, inputFrame, replayedFrames } from "./test-support.js"

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

    // The screen comes back as a reconstruction, followed by the synthetic
    // exit (the process died with the previous server).
    expect(await run(restored.readScreen(created.terminalId, "text"))).toBe("hello world")
    const frames: Array<TerminalServerFrame> = []
    const detach = await run(
      restored.connectTerminal(created.terminalId, 1, (frame) => {
        if (frame.type !== "size") frames.push(frame)
      })
    )
    expect(frames.map((frame) => [frame.type, frame.seq])).toEqual([
      ["output", 3],
      ["exit", 3]
    ])
    expect(frames[0]).toMatchObject({ reset: true })
    // A client that had already seen everything only learns of the exit.
    expect(await run(replayedFrames(restored, created.terminalId, 2))).toEqual([
      { type: "exit", seq: 3 }
    ])

    // Input is refused: the restored terminal is closed and process-less.
    await expect(
      run(restored.handleClientFrame(created.terminalId, inputFrame(2, "pwd\n")))
    ).rejects.toBeInstanceOf(TerminalError)
    // Once its last reader leaves, the dead shell is dropped.
    detach()
    await expect(run(restored.readScreen(created.terminalId, "text"))).rejects.toBeInstanceOf(
      TerminalError
    )

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
    const frames = await run(replayedFrames(restored, handle.terminalId))
    expect(frames.map((frame) => frame.type)).toEqual(["output", "exit"])
    expect(frames[1]).toEqual({ type: "exit", seq: 2, exitCode: 0 })
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
    const frames = await run(replayedFrames(manager, handle.terminalId))
    expect(frames.filter((frame) => frame.type === "output")).toHaveLength(2)
    expect(frames.filter((frame) => frame.type === "exit")).toHaveLength(0)
  })

  it("restores version 1 snapshots, which carry raw frames", async () => {
    const restored = makeTerminalManager({ spawner: makeSpawner() })
    restored.restoreTerminals({
      version: 1,
      terminals: [
        {
          terminalId: "legacy",
          sessionId: "legacy:bg",
          nextOutputSeq: 3,
          closed: true,
          external: true,
          frames: [
            { type: "output", seq: 1, data: "old format" },
            { type: "exit", seq: 2, exitCode: 1 }
          ]
        }
      ]
    })
    expect(await run(replayedFrames(restored, "legacy"))).toEqual([
      { type: "output", seq: 1, data: "old format" },
      { type: "exit", seq: 2, exitCode: 1 }
    ])
    expect(await run(restored.readScreen("legacy", "text"))).toBe("old format")
  })

  it("reads a terminal's screen as text or VT and tracks output revisions", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const created = await run(
      manager.createTerminal({ sessionId: "screen-read", cwd: "/", cols: 80, rows: 24 })
    )
    const before = manager.outputRevision()
    spawner.handlers[0]?.onOutput("\u001b[1mbold\u001b[0m text")
    expect(manager.outputRevision()).toBe(before + 1)
    expect(await run(manager.readScreen(created.terminalId, "text"))).toBe("bold text")
    const vt = await run(manager.readScreen(created.terminalId, "vt"))
    expect(vt.startsWith("\u001bc")).toBe(true)
    expect(vt).toContain("bold")
    await expect(run(manager.readScreen("missing", "text"))).rejects.toBeInstanceOf(TerminalError)
  })
})
