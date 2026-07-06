import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { BackgroundTerminalRegistry } from "../background-terminals.js"
import type { RuntimeEvent } from "../types.js"
import {
  makeAcpTerminalHost,
  type AcpTerminalChild,
  type AcpTerminalSpawner
} from "./acp-terminals.js"

class FakeChild implements AcpTerminalChild {
  readonly writes: Array<string> = []
  killCount = 0
  private outputCallback: ((data: string) => void) | undefined
  private exitCallback:
    | ((exitCode: number | undefined, signal: string | undefined) => void)
    | undefined

  onOutput(callback: (data: string) => void): void {
    this.outputCallback = callback
  }

  onExit(callback: (exitCode: number | undefined, signal: string | undefined) => void): void {
    this.exitCallback = callback
  }

  write(data: string): void {
    this.writes.push(data)
  }

  kill(): void {
    this.killCount += 1
    this.exitCallback?.(undefined, "SIGTERM")
  }

  emitOutput(data: string): void {
    this.outputCallback?.(data)
  }

  emitExit(exitCode: number | undefined, signal?: string): void {
    this.exitCallback?.(exitCode, signal)
  }
}

interface RegisteredTerminal {
  readonly key: string
  readonly controls: {
    readonly write?: (data: string) => void
    readonly kill?: () => void
  }
  readonly outputs: Array<string>
  readonly exits: Array<number | undefined>
  removed: boolean
}

const makeFakeRegistry = (): {
  readonly registry: BackgroundTerminalRegistry
  readonly registered: Array<RegisteredTerminal>
} => {
  const registered: Array<RegisteredTerminal> = []
  return {
    registered,
    registry: {
      register: (key, controls) => {
        const entry: RegisteredTerminal = {
          controls,
          exits: [],
          key,
          outputs: [],
          removed: false
        }
        registered.push(entry)
        return {
          exit: (exitCode) => entry.exits.push(exitCode),
          output: (data) => entry.outputs.push(data),
          remove: () => {
            entry.removed = true
          }
        }
      }
    }
  }
}

const makeHost = (options?: { promotionDelayMs?: number }) => {
  const children: Array<FakeChild> = []
  const spawns: Array<{
    command: string
    args: ReadonlyArray<string>
    cwd?: string
    env: NodeJS.ProcessEnv
  }> = []
  const spawner: AcpTerminalSpawner = (command, args, spawnOptions) => {
    const child = new FakeChild()
    children.push(child)
    spawns.push({
      args,
      command,
      env: spawnOptions.env,
      ...(spawnOptions.cwd === undefined ? {} : { cwd: spawnOptions.cwd })
    })
    return child
  }
  const events: Array<RuntimeEvent> = []
  const fake = makeFakeRegistry()
  const host = makeAcpTerminalHost({
    emit: async (event) => {
      events.push(event)
    },
    env: { PATH: "/bin" },
    integration: {
      registry: fake.registry,
      promotionDelayMs: options?.promotionDelayMs ?? 50
    },
    spawner
  })
  return { children, events, host, registered: fake.registered, spawns }
}

const taskSnapshots = (events: ReadonlyArray<RuntimeEvent>) =>
  events
    .filter((event) => event.kind === "session.updated")
    .map((event) => event.payload as { backgroundTasks: Array<Record<string, unknown>> })
    .map((payload) => payload.backgroundTasks)

describe("makeAcpTerminalHost", () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("spawns commands with merged env, buffers output, and reports exits", async () => {
    const { children, host, registered, spawns } = makeHost()
    const { terminalId } = host.create({
      args: ["dev"],
      command: "pnpm",
      cwd: "/repo",
      env: [{ name: "PORT", value: "3000" }],
      sessionId: "session-1"
    })

    expect(spawns[0]).toMatchObject({
      args: ["dev"],
      command: "pnpm",
      cwd: "/repo",
      env: { PATH: "/bin", PORT: "3000" }
    })
    expect(registered[0]?.key).toBe("session-1:bg:" + terminalId)

    children[0]?.emitOutput("ready on :3000\n")
    expect(host.output({ sessionId: "session-1", terminalId })).toEqual({
      output: "ready on :3000\n",
      truncated: false
    })
    expect(registered[0]?.outputs).toEqual(["ready on :3000\n"])

    // Input/kill controls forward to the child process.
    registered[0]?.controls.write?.("q")
    expect(children[0]?.writes).toEqual(["q"])

    const waited = host.waitForExit({ sessionId: "session-1", terminalId })
    children[0]?.emitExit(0)
    expect(await waited).toEqual({ exitCode: 0 })
    expect(registered[0]?.exits).toEqual([0])
    // Post-exit polls still work, and resolve immediately.
    expect(host.output({ sessionId: "session-1", terminalId }).exitStatus).toEqual({ exitCode: 0 })
    expect(await host.waitForExit({ sessionId: "session-1", terminalId })).toEqual({ exitCode: 0 })

    // Released after exit without promotion: nothing left behind.
    host.release({ sessionId: "session-1", terminalId })
    expect(registered[0]?.removed).toBe(true)
    expect(() => host.output({ sessionId: "session-1", terminalId })).toThrow(/Unknown terminal/)
  })

  it("truncates buffered output from the beginning at a character boundary", () => {
    const { children, host } = makeHost()
    const { terminalId } = host.create({
      command: "yes",
      outputByteLimit: 4,
      sessionId: "session-1"
    })
    children[0]?.emitOutput("abcdef")
    children[0]?.emitOutput("éxyz")
    const output = host.output({ sessionId: "session-1", terminalId })
    expect(output.truncated).toBe(true)
    // The 4-byte tail would split "é" in half; the partial byte is dropped.
    expect(output.output).toBe("xyz")
    expect(Buffer.byteLength(output.output, "utf8")).toBeLessThanOrEqual(4)
  })

  it("promotes long-lived commands to background tasks and clears them on exit", () => {
    const { children, events, host, registered } = makeHost({ promotionDelayMs: 50 })
    const { terminalId } = host.create({
      args: ["run", "dev"],
      command: "npm",
      sessionId: "session-2"
    })

    // Not promoted yet: no snapshots.
    expect(taskSnapshots(events)).toEqual([])
    vi.advanceTimersByTime(50)
    expect(taskSnapshots(events).at(-1)).toEqual([
      {
        description: "npm run dev",
        id: terminalId,
        status: "running",
        taskType: "shell",
        terminalKey: `session-2:bg:${terminalId}`
      }
    ])

    // Exit removes the task from the snapshot but keeps the terminal (the
    // tab's scrollback) and the entry for post-exit polls.
    children[0]?.emitExit(1)
    expect(taskSnapshots(events).at(-1)).toEqual([])
    expect(registered[0]?.removed).toBe(false)
    expect(host.output({ sessionId: "session-2", terminalId }).exitStatus).toEqual({ exitCode: 1 })

    // Releasing a promoted terminal drops the entry, not the scrollback.
    host.release({ sessionId: "session-2", terminalId })
    expect(registered[0]?.removed).toBe(false)
  })

  it("kills on kill/release and removes short-lived terminals on release", () => {
    const { children, events, host, registered } = makeHost({ promotionDelayMs: 50 })
    const { terminalId } = host.create({ command: "sleep", args: ["100"], sessionId: "session-3" })

    host.kill({ sessionId: "session-3", terminalId })
    expect(children[0]?.killCount).toBe(1)
    // Kill without release keeps the entry queryable (signal exit, no code).
    expect(host.output({ sessionId: "session-3", terminalId }).exitStatus).toEqual({
      signal: "SIGTERM"
    })
    // Killing an already-exited terminal is a no-op.
    host.kill({ sessionId: "session-3", terminalId })
    expect(children[0]?.killCount).toBe(1)

    host.release({ sessionId: "session-3", terminalId })
    expect(registered[0]?.removed).toBe(true)

    // Releasing a still-running short-lived terminal kills it and cleans up.
    const second = host.create({ command: "sleep", args: ["100"], sessionId: "session-3" })
    host.release({ sessionId: "session-3", terminalId: second.terminalId })
    expect(children[1]?.killCount).toBe(1)
    expect(registered[1]?.removed).toBe(true)
    // The promotion timer never fires for it.
    vi.advanceTimersByTime(1000)
    expect(taskSnapshots(events)).toEqual([])
  })

  it("closeAll kills running commands and keeps promoted scrollback", () => {
    const { children, host, registered } = makeHost({ promotionDelayMs: 10 })
    const promotedTerminal = host.create({ command: "npm", args: ["start"], sessionId: "s" })
    vi.advanceTimersByTime(10)
    host.create({ command: "sleep", sessionId: "s" })

    host.closeAll()
    expect(children[0]?.killCount).toBe(1)
    expect(children[1]?.killCount).toBe(1)
    // Promoted terminal keeps its registry stream (tab scrollback survives).
    expect(registered[0]?.removed).toBe(false)
    // The short-lived one is removed entirely.
    expect(registered[1]?.removed).toBe(true)
    expect(() => host.output({ sessionId: "s", terminalId: promotedTerminal.terminalId })).toThrow(
      /Unknown terminal/
    )
  })
})
