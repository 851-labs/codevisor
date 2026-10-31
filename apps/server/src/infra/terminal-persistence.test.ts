import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { makeTerminalManager, type TerminalProcess } from "@codevisor/terminal"
import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { makeTerminalPersistence } from "./terminal-persistence.js"

const noopProcess: TerminalProcess = {
  write: () => undefined,
  resize: () => undefined,
  kill: () => undefined
}

const directories: Array<string> = []

const makeDataDir = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-terminal-persistence-"))
  directories.push(dir)
  return dir
}

afterEach(() => {
  for (const dir of directories.splice(0)) {
    rmSync(dir, { recursive: true, force: true })
  }
})

describe("terminal persistence", () => {
  it("round-trips terminal buffers through flush and restore", () => {
    const dataDir = makeDataDir()
    const first = makeTerminalManager()
    const handle = first.registerExternalTerminal({ sessionId: "plugin:demo" }, noopProcess)
    handle.output("plugin output\r\n")
    makeTerminalPersistence({ dataDir, terminal: first }).flush()

    const second = makeTerminalManager()
    const lines: Array<string> = []
    makeTerminalPersistence({
      dataDir,
      terminal: second,
      log: (line) => lines.push(line)
    }).restore()

    expect(lines).toEqual(["Restored 1 terminal buffer(s) from previous run"])
    expect(existsSync(join(dataDir, "terminal-buffers.json"))).toBe(false)
    expect(second.snapshotTerminals().terminals).toMatchObject([
      {
        terminalId: handle.terminalId,
        sessionId: "plugin:demo",
        closed: true,
        external: true,
        nextOutputSeq: 3
      }
    ])
    expect(Effect.runSync(second.readScreen(handle.terminalId, "text"))).toBe("plugin output")
  })

  it("reports actual restored terminal counts across batches", () => {
    const dataDir = makeDataDir()
    const first = makeTerminalManager()
    for (let index = 0; index < 65; index += 1) {
      first
        .registerExternalTerminal({ sessionId: `terminal:${index}` }, noopProcess)
        .output(`output:${index}`)
    }
    makeTerminalPersistence({ dataDir, terminal: first }).flush()
    const second = makeTerminalManager()
    const progress: number[][] = []
    makeTerminalPersistence({
      dataDir,
      terminal: second,
      onRestoreProgress: (done, total) => progress.push([done, total])
    }).restore()
    expect(progress).toEqual([
      [0, 65],
      [32, 65],
      [64, 65],
      [65, 65]
    ])
    expect(second.snapshotTerminals().terminals).toHaveLength(65)
  })

  it("skips empty snapshots, missing or corrupt files, and unknown versions", () => {
    const dataDir = makeDataDir()
    const manager = makeTerminalManager()
    const persistence = makeTerminalPersistence({ dataDir, terminal: manager })

    persistence.restore()
    expect(manager.snapshotTerminals().terminals).toEqual([])

    persistence.flush()
    const snapshotPath = join(dataDir, "terminal-buffers.json")
    expect(existsSync(snapshotPath)).toBe(false)

    writeFileSync(snapshotPath, "{not json")
    persistence.restore()
    expect(existsSync(snapshotPath)).toBe(false)
    expect(manager.snapshotTerminals().terminals).toEqual([])

    writeFileSync(
      snapshotPath,
      JSON.stringify({
        version: 99,
        terminals: [
          { terminalId: "t", sessionId: "s", nextOutputSeq: 1, closed: true, external: false }
        ]
      })
    )
    const lines: Array<string> = []
    const logged = makeTerminalPersistence({
      dataDir,
      terminal: manager,
      log: (line) => lines.push(line)
    })
    logged.restore()
    writeFileSync(snapshotPath, JSON.stringify({ version: 1, terminals: "nope" }))
    logged.restore()
    writeFileSync(snapshotPath, JSON.stringify({ version: 1, terminals: [] }))
    logged.restore()
    expect(manager.snapshotTerminals().terminals).toEqual([])
    expect(lines).toEqual([])
  })

  it("never lets persistence failures escape restore or flush", () => {
    const dataDir = makeDataDir()
    const manager = makeTerminalManager()
    const snapshotPath = join(dataDir, "terminal-buffers.json")

    const lines: Array<string> = []
    writeFileSync(
      snapshotPath,
      JSON.stringify({
        version: 1,
        terminals: [
          { terminalId: "t", sessionId: "s", nextOutputSeq: 1, closed: true, external: false }
        ]
      })
    )
    makeTerminalPersistence({
      dataDir,
      terminal: {
        ...manager,
        restoreTerminals: () => {
          throw "boom"
        }
      },
      log: (line) => lines.push(line)
    }).restore()
    expect(lines).toEqual(["Terminal buffer restore skipped: boom"])

    makeTerminalPersistence({
      dataDir,
      terminal: {
        ...manager,
        snapshotTerminals: () => {
          throw new Error("boom")
        }
      }
    }).flush()
    expect(existsSync(snapshotPath)).toBe(false)
  })

  it("writes snapshots atomically with owner-only permissions", () => {
    const dataDir = makeDataDir()
    const manager = makeTerminalManager()
    const handle = manager.registerExternalTerminal({ sessionId: "agent:bg:1" }, noopProcess)
    handle.output("data")
    makeTerminalPersistence({ dataDir, terminal: manager }).flush()

    const snapshotPath = join(dataDir, "terminal-buffers.json")
    expect(existsSync(`${snapshotPath}.tmp`)).toBe(false)
    expect(JSON.parse(readFileSync(snapshotPath, "utf8"))).toMatchObject({ version: 3 })
    expect(statSync(snapshotPath).mode & 0o777).toBe(0o600)
  })

  it("flushes through the exit hook and exits with conventional signal codes", () => {
    const dataDir = makeDataDir()
    const manager = makeTerminalManager()
    const handle = manager.registerExternalTerminal({ sessionId: "agent:bg:exit" }, noopProcess)
    handle.output("late output")

    const handlers = new Map<string, () => void>()
    const exits: Array<number> = []
    makeTerminalPersistence({
      dataDir,
      terminal: manager,
      processHandle: {
        on: (event, handler) => handlers.set(event, handler),
        exit: (code) => exits.push(code)
      }
    }).installExitHooks()

    handlers.get("SIGTERM")?.()
    handlers.get("SIGINT")?.()
    expect(exits).toEqual([143, 130])
    expect(existsSync(join(dataDir, "terminal-buffers.json"))).toBe(false)
    handlers.get("exit")?.()
    expect(existsSync(join(dataDir, "terminal-buffers.json"))).toBe(true)
  })

  it("flushes periodically, but only after new output", () => {
    const dataDir = makeDataDir()
    const manager = makeTerminalManager()
    const handle = manager.registerExternalTerminal({ sessionId: "agent:bg:tick" }, noopProcess)
    handle.output("first")
    const ticks: Array<{ run: () => void; ms: number; unrefs: number }> = []
    makeTerminalPersistence({
      dataDir,
      terminal: manager,
      setInterval: (run, ms) => {
        const tick = { run, ms, unrefs: 0 }
        ticks.push(tick)
        return { unref: () => (tick.unrefs += 1) }
      }
    }).startPeriodicFlush()
    const tick = ticks[0]!
    expect(tick.ms).toBe(30_000)
    expect(tick.unrefs).toBe(1)

    const snapshotPath = join(dataDir, "terminal-buffers.json")
    tick.run()
    expect(existsSync(snapshotPath)).toBe(true)
    rmSync(snapshotPath)
    tick.run()
    expect(existsSync(snapshotPath)).toBe(false)
    handle.output("second")
    tick.run()
    expect(existsSync(snapshotPath)).toBe(true)
  })
})
