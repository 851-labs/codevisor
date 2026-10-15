import type { TerminalServerFrame } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeTerminalManager, TerminalError } from "./index.js"
import { REPLAY_BUFFER_MAX_BYTES } from "./replay-buffer.js"
import {
  clientFrame,
  FakeProcess,
  makeSpawner,
  replayedFrames,
  resizeFrame,
  run,
  type ClientFrameBody
} from "./test-support.js"
import { createVtTerminal } from "./vt/ghostty-vt.js"

const screenText = (frames: ReadonlyArray<TerminalServerFrame>, cols = 80): string => {
  const replica = createVtTerminal({ cols, rows: 24 })
  for (const frame of frames) if (frame.type === "output") replica.write(frame.data)
  const text = replica.text()
  replica.free()
  return text
}

const overflow = (): string => "y".repeat(REPLAY_BUFFER_MAX_BYTES + 1)

describe("@codevisor/terminal server-side screen", () => {
  it("resyncs a lagging client to the current screen, then the exit", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const created = await run(
      manager.createTerminal({ sessionId: "screen-1", cwd: "/", cols: 80, rows: 24 })
    )
    const live: Array<TerminalServerFrame> = []
    const disconnect = await run(
      manager.connectTerminal(created.terminalId, 0, (f) => live.push(f))
    )
    spawner.handlers[0]?.onOutput("\u001b[2J\u001b[Hold screen")
    spawner.handlers[0]?.onOutput(overflow())
    spawner.handlers[0]?.onOutput("\u001b[2J\u001b[Hcurrent screen")
    spawner.handlers[0]?.onExit(3)

    const frames = await run(replayedFrames(manager, created.terminalId))
    expect(frames.map((frame) => [frame.type, frame.seq])).toEqual([
      ["output", 4],
      ["exit", 4]
    ])
    expect(frames[1]).toMatchObject({ exitCode: 3 })
    expect(screenText(frames)).toBe(screenText(live))
    expect(screenText(frames).endsWith("current screen")).toBe(true)
    disconnect()
  })

  it("answers terminal queries only while no client is attached", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const created = await run(
      manager.createTerminal({ sessionId: "screen-2", cwd: "/", cols: 80, rows: 24 })
    )
    const process = spawner.processes[0]!
    spawner.handlers[0]?.onOutput("\u001b[6n")
    expect(process.writes).toEqual(["\u001b[1;1R"])

    const disconnect = await run(manager.connectTerminal(created.terminalId, 0, () => undefined))
    spawner.handlers[0]?.onOutput("\u001b[6n")
    expect(process.writes).toHaveLength(1)
    disconnect()

    const restored = makeTerminalManager({ spawner })
    const handle = manager.registerExternalTerminal({ sessionId: "screen-2:bg" }, new FakeProcess())
    handle.output("\u001b[6n")
    restored.restoreTerminals(manager.snapshotTerminals())
    expect(await run(replayedFrames(restored, handle.terminalId))).toHaveLength(2)
  })

  it("keeps the screen sized with the PTY and rejects empty sizes", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const created = await run(
      manager.createTerminal({ sessionId: "screen-3", cwd: "/", cols: 80, rows: 24 })
    )
    await run(manager.handleClientFrame(created.terminalId, resizeFrame(1, 20, 5)))
    spawner.handlers[0]?.onOutput("a".repeat(25))
    spawner.handlers[0]?.onOutput(overflow().slice(0, REPLAY_BUFFER_MAX_BYTES))
    spawner.handlers[0]?.onOutput("\u001b[2J\u001b[H" + "b".repeat(25))
    const frames = await run(replayedFrames(manager, created.terminalId))
    expect(screenText(frames, 20).split("\n").slice(-2)).toEqual(["b".repeat(20), "b".repeat(5)])
    await expect(
      run(manager.handleClientFrame(created.terminalId, resizeFrame(2, 0, 5)))
    ).rejects.toBeInstanceOf(TerminalError)
  })

  it("keeps sequencing late output from a removed external terminal", () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    const handle = manager.registerExternalTerminal({ sessionId: "screen-4" }, new FakeProcess())
    handle.remove()
    expect(() => handle.output("after removal")).not.toThrow()
  })

  it("sizes the PTY for the client being typed on, and tells every client", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const created = await run(
      manager.createTerminal({ sessionId: "screen-5", cwd: "/", cols: 80, rows: 24 })
    )
    const sizes: Array<TerminalServerFrame> = []
    await run(
      manager.connectTerminal(created.terminalId, 0, (f) => {
        if (f.type === "size") sizes.push(f)
      })
    )
    const frame = (clientId: string, clientSeq: number, body: ClientFrameBody) =>
      run(manager.handleClientFrame(created.terminalId, clientFrame(clientId, clientSeq, body)))
    await frame("mac", 1, { type: "resize", cols: 200, rows: 50 })
    await frame("phone", 1, { type: "resize", cols: 60, rows: 30 })
    await frame("phone", 2, { type: "input", data: "\u001b[?62c", claim: false })
    await frame("phone", 3, { type: "focus" })
    await frame("mac", 2, { type: "input", data: "s" })
    await frame("tablet", 1, { type: "hide" })
    await frame("mac", 3, { type: "hide" })
    manager.releaseClient(created.terminalId, "phone")
    manager.releaseClient("missing", "phone")
    expect(spawner.processes[0]?.resizes).toEqual([
      [200, 50],
      [60, 30],
      [200, 50],
      [60, 30]
    ])
    expect(spawner.processes[0]?.writes).toEqual(["\u001b[?62c", "s"])
    expect(sizes.map((f) => (f.type === "size" ? [f.cols, f.rows] : []))).toEqual([
      [80, 24],
      [200, 50],
      [60, 30],
      [200, 50],
      [60, 30]
    ])
    await frame("mac", 4, { type: "resize", cols: 100, rows: 40 })
    spawner.handlers[0]?.onExit(0)
    manager.releaseClient(created.terminalId, "mac")
    expect(spawner.processes[0]?.resizes).toHaveLength(5)
  })

  it("clears every client at once, redrawing the prompt only at the shell", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const created = await run(
      manager.createTerminal({ sessionId: "screen-6", cwd: "/", cols: 80, rows: 24 })
    )
    const live: Array<TerminalServerFrame> = []
    await run(manager.connectTerminal(created.terminalId, 0, (f) => live.push(f)))
    spawner.handlers[0]?.onOutput("old output\r\n$ ")
    const clear = (clientSeq: number) =>
      run(
        manager.handleClientFrame(created.terminalId, {
          type: "clear",
          clientId: "mac",
          clientSeq
        })
      )

    await clear(1)
    expect(live.at(-1)).toMatchObject({ data: "\u001b[H\u001b[2J\u001b[3J" })
    expect(spawner.processes[0]?.writes).toEqual(["\f"])
    expect(await run(manager.readScreen(created.terminalId, "text"))).toBe("")

    spawner.processes[0]!.shellInForeground = false
    await clear(2)
    expect(live.at(-1)).toMatchObject({ data: "\u001b[3J" })
    expect(spawner.processes[0]?.writes).toEqual(["\f"])

    const handle = manager.registerExternalTerminal(
      { sessionId: "screen-6:bg" },
      {
        write: () => undefined,
        resize: () => undefined,
        kill: () => undefined
      }
    )
    const frames: Array<TerminalServerFrame> = []
    await run(manager.connectTerminal(handle.terminalId, 0, (f) => frames.push(f)))
    await run(
      manager.handleClientFrame(handle.terminalId, { type: "clear", clientId: "a", clientSeq: 1 })
    )
    expect(frames.at(-1)).toMatchObject({ data: "\u001b[3J" })
  })
})
