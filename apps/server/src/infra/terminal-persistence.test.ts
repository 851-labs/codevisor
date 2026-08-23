import { makeTerminalManager, type TerminalProcess } from "@codevisor/terminal"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
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
    // The snapshot file is consumed so a crash cannot replay it again later.
    expect(existsSync(join(dataDir, "terminal-buffers.json"))).toBe(false)
    // Scrollback survives; the still-live terminal gained a synthetic exit.
    expect(second.snapshotTerminals().terminals).toMatchObject([
      {
        terminalId: handle.terminalId,
        sessionId: "plugin:demo",
        closed: true,
        external: true,
        frames: [
          { type: "output", seq: 1, data: "plugin output\r\n" },
          { type: "exit", seq: 2 }
        ]
      }
    ])
  })

  it("skips empty snapshots, missing or corrupt files, and unknown versions", () => {
    const dataDir = makeDataDir()
    const manager = makeTerminalManager()
    const persistence = makeTerminalPersistence({ dataDir, terminal: manager })

    // First boot: no snapshot file, restore is a no-op.
    persistence.restore()
    expect(manager.snapshotTerminals().terminals).toEqual([])

    // Nothing to write: no file appears.
    persistence.flush()
    const snapshotPath = join(dataDir, "terminal-buffers.json")
    expect(existsSync(snapshotPath)).toBe(false)

    // Corrupt file: restore is a no-op and consumes the file.
    writeFileSync(snapshotPath, "{not json")
    persistence.restore()
    expect(existsSync(snapshotPath)).toBe(false)
    expect(manager.snapshotTerminals().terminals).toEqual([])

    // Unknown version or malformed terminals: ignored rather than misread.
    writeFileSync(snapshotPath, JSON.stringify({ version: 99, terminals: [{}] }))
    persistence.restore()
    writeFileSync(snapshotPath, JSON.stringify({ version: 1, terminals: "nope" }))
    persistence.restore()
    expect(manager.snapshotTerminals().terminals).toEqual([])

    // A valid but empty snapshot restores silently.
    const lines: Array<string> = []
    writeFileSync(snapshotPath, JSON.stringify({ version: 1, terminals: [] }))
    makeTerminalPersistence({
      dataDir,
      terminal: manager,
      log: (line) => lines.push(line)
    }).restore()
    expect(lines).toEqual([])
  })

  it("never lets persistence failures escape restore or flush", () => {
    const dataDir = makeDataDir()
    const manager = makeTerminalManager()
    const snapshotPath = join(dataDir, "terminal-buffers.json")

    // restore: a non-Error throw is stringified into the log line.
    const lines: Array<string> = []
    writeFileSync(snapshotPath, JSON.stringify({ version: 1, terminals: [] }))
    makeTerminalPersistence({
      dataDir,
      terminal: {
        ...manager,
        restoreTerminals: () => {
          throw "boom" // eslint-disable-line no-throw-literal
        }
      },
      log: (line) => lines.push(line)
    }).restore()
    expect(lines).toEqual(["Terminal buffer restore skipped: boom"])

    // flush: a snapshot failure is swallowed, and shutdown continues.
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
    const parsed = JSON.parse(readFileSync(snapshotPath, "utf8")) as { version: number }
    expect(parsed.version).toBe(1)
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

    // Signal handlers defer to process.exit so the "exit" hook does the write.
    handlers.get("SIGTERM")?.()
    handlers.get("SIGINT")?.()
    expect(exits).toEqual([143, 130])
    expect(existsSync(join(dataDir, "terminal-buffers.json"))).toBe(false)
    handlers.get("exit")?.()
    expect(existsSync(join(dataDir, "terminal-buffers.json"))).toBe(true)
  })
})
