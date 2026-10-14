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
    expect(await run(replayedFrames(restored, created.terminalId, 2))).toEqual([
      { type: "exit", seq: 3 }
    ])

    await expect(
      run(restored.handleClientFrame(created.terminalId, inputFrame(2, "pwd\n")))
    ).rejects.toBeInstanceOf(TerminalError)
    detach()
    await expect(run(restored.readScreen(created.terminalId, "text"))).rejects.toBeInstanceOf(
      TerminalError
    )

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

    handle.output("still live")
    const frames = await run(replayedFrames(manager, handle.terminalId))
    expect(frames.filter((frame) => frame.type === "output")).toHaveLength(2)
    expect(frames.filter((frame) => frame.type === "exit")).toHaveLength(0)
  })

  it("skips external terminals from snapshots before version 3", async () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    manager.registerExternalTerminal({ sessionId: "agent:bg:old" }, new FakeProcess()).exit(0)
    const restored = makeTerminalManager({ spawner: makeSpawner() })
    restored.restoreTerminals({ ...manager.snapshotTerminals(), version: 2 })
    await expect(
      run(
        restored.createTerminal({
          sessionId: "agent:bg:old",
          cwd: "/",
          cols: 1,
          rows: 1,
          attachOnly: true
        })
      )
    ).rejects.toBeInstanceOf(TerminalError)
  })

  it("restores version 1 snapshots, which carry raw frames", async () => {
    const restored = makeTerminalManager({ spawner: makeSpawner() })
    restored.restoreTerminals({
      version: 1,
      terminals: [
        {
          terminalId: "legacy",
          sessionId: "legacy",
          nextOutputSeq: 3,
          closed: true,
          external: false,
          frames: [
            { type: "output", seq: 1, data: "old format" },
            { type: "exit", seq: 2, exitCode: 1 }
          ]
        }
      ]
    })
    expect(await run(restored.readScreen("legacy", "text"))).toBe("old format")
    expect(await run(replayedFrames(restored, "legacy"))).toEqual([
      { type: "output", seq: 1, data: "old format" },
      { type: "exit", seq: 2, exitCode: 1 }
    ])
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
