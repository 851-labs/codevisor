import type {
  TerminalHandlers,
  TerminalProcess,
  TerminalSpawnRequest,
  TerminalSpawner
} from "./index.js"
import type { TerminalClientFrame } from "@codevisor/api"
import { Effect } from "effect"
import { existsSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { makeTerminalManager, TerminalError, TerminalManager } from "./index.js"

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

class FakeProcess implements TerminalProcess {
  readonly writes: Array<string> = []
  readonly resizes: Array<readonly [number, number]> = []
  killCount = 0

  write(data: string): void {
    this.writes.push(data)
  }

  resize(cols: number, rows: number): void {
    this.resizes.push([cols, rows])
  }

  kill(): void {
    this.killCount += 1
  }
}

const makeSpawner = (
  onSpawn?: (
    request: TerminalSpawnRequest,
    handlers: TerminalHandlers,
    process: FakeProcess
  ) => void
): TerminalSpawner & {
  readonly requests: ReadonlyArray<TerminalSpawnRequest>
  readonly handlers: ReadonlyArray<TerminalHandlers>
  readonly processes: ReadonlyArray<FakeProcess>
} => {
  const requests: Array<TerminalSpawnRequest> = []
  const handlersList: Array<TerminalHandlers> = []
  const processes: Array<FakeProcess> = []
  return {
    requests,
    handlers: handlersList,
    processes,
    spawn: (request, handlers) =>
      Effect.sync(() => {
        const process = new FakeProcess()
        requests.push(request)
        handlersList.push(handlers)
        processes.push(process)
        onSpawn?.(request, handlers, process)
        return process
      })
  }
}

describe("@codevisor/terminal", () => {
  it("creates terminals through an Effect layer and rejects invalid dimensions", async () => {
    const spawner = makeSpawner()
    const response = await run(
      Effect.gen(function* () {
        const manager = yield* TerminalManager
        return yield* manager.createTerminal({
          sessionId: "session-1",
          cwd: "/tmp/project",
          cols: 80,
          rows: 24
        })
      }).pipe(Effect.provide(TerminalManager.layer({ defaultShell: "/bin/zsh", env: {}, spawner })))
    )

    expect(response.websocketPath).toBe(`/v1/terminals/${response.terminalId}/socket`)
    expect(spawner.requests[0]).toMatchObject({
      cols: 80,
      cwd: "/tmp/project",
      rows: 24,
      shell: "/bin/zsh"
    })

    const manager = makeTerminalManager({ spawner })
    await expect(
      run(
        manager.createTerminal({
          sessionId: "session-1",
          cwd: "/tmp/project",
          cols: 0,
          rows: 24
        })
      )
    ).rejects.toBeInstanceOf(TerminalError)
  })

  it("launches shells with the bundled Ghostty terminal environment", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: {
        COLORTERM: "legacy",
        TERM: "xterm-256color",
        TERMINFO: "/tmp/missing",
        TERM_PROGRAM: "other"
      },
      spawner
    })

    await run(
      manager.createTerminal(
        { sessionId: "session-ghostty", cwd: "/tmp", cols: 80, rows: 24 },
        { TERM: "vt100" }
      )
    )

    const terminalEnv = spawner.requests[0]?.env
    expect(terminalEnv).toMatchObject({
      COLORTERM: "truecolor",
      TERM: "xterm-ghostty",
      TERM_PROGRAM: "ghostty"
    })
    const terminfoDirectory = terminalEnv?.TERMINFO
    expect(terminfoDirectory).toBeTypeOf("string")
    expect(existsSync(join(terminfoDirectory!, "78", "xterm-ghostty"))).toBe(true)
    expect(existsSync(join(terminfoDirectory!, "67", "ghostty"))).toBe(true)
  })

  it("prefers an executable SHELL from the manager environment", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: { SHELL: "/bin/zsh" },
      executableExists: () => true,
      userShell: () => "/bin/bash",
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-env-shell",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.shell).toBe("/bin/zsh")
  })

  it("uses the passwd shell when a service environment has no SHELL", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: {},
      executableExists: (path) => path === "/usr/bin/fish",
      userShell: () => "/usr/bin/fish",
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-passwd-shell",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.shell).toBe("/usr/bin/fish")
  })

  it("skips unusable discovered shells and falls back to /bin/sh", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: { SHELL: "/missing/env-shell" },
      executableExists: () => false,
      userShell: () => "/missing/passwd-shell",
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-fallback-shell",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.shell).toBe("/bin/sh")
  })

  it("falls back when an automatically discovered shell is not executable", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: { SHELL: "/codevisor-test/missing-shell" },
      userShell: () => undefined,
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-missing-shell",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.shell).toBe("/bin/sh")
  })

  it("buffers early process frames and rejects input after an early exit", async () => {
    const spawner = makeSpawner((_request, handlers) => {
      handlers.onOutput("booting")
      handlers.onExit(undefined)
    })
    const manager = makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })

    const terminal = await run(
      manager.createTerminal({
        sessionId: "session-1",
        cwd: "/tmp/project",
        cols: 120,
        rows: 30
      })
    )
    const frames: Array<unknown> = []
    const disconnect = await run(
      manager.connectTerminal(terminal.terminalId, 0, (frame) => frames.push(frame))
    )
    disconnect()

    expect(frames).toEqual([
      { type: "output", seq: 1, data: "booting" },
      { type: "exit", seq: 2 }
    ])
    await expect(
      run(manager.handleClientFrame(terminal.terminalId, inputFrame(1, "ignored")))
    ).rejects.toBeInstanceOf(TerminalError)
  })

  it("handles idempotent creation, input, resize, live output, replay, and removal", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ defaultShell: "/bin/sh", env: { PATH: "/bin" }, spawner })
    const terminal = await run(
      manager.createTerminal({
        sessionId: "session-2",
        cwd: "/tmp/other",
        cols: 100,
        rows: 40,
        shell: "/bin/bash"
      })
    )
    const firstSink: Array<unknown> = []
    const disconnect = await run(
      manager.connectTerminal(terminal.terminalId, 0, (frame) => firstSink.push(frame))
    )

    const sameTerminal = await run(
      manager.createTerminal({
        sessionId: "session-2",
        cwd: "/tmp/other",
        cols: 100,
        rows: 40
      })
    )
    expect(sameTerminal.terminalId).toBe(terminal.terminalId)

    await run(manager.handleClientFrame(terminal.terminalId, inputFrame(1, "ls\n")))
    await run(manager.handleClientFrame(terminal.terminalId, inputFrame(1, "duplicate\n")))
    await run(manager.handleClientFrame(terminal.terminalId, resizeFrame(2, 140, 50)))
    await run(manager.handleClientFrame(terminal.terminalId, resizeFrame(2, 1, 1)))
    spawner.handlers[0]?.onOutput("hello")
    spawner.handlers[0]?.onExit(7)
    disconnect()
    spawner.handlers[0]?.onOutput("after-disconnect")

    const process = spawner.processes[0]
    expect(spawner.requests[0]).toMatchObject({ shell: "/bin/bash", env: { PATH: "/bin" } })
    expect(process?.writes).toEqual(["ls\n"])
    expect(process?.resizes).toEqual([[140, 50]])
    expect(firstSink).toEqual([
      { type: "output", seq: 1, data: "hello" },
      { type: "exit", seq: 2, exitCode: 7 }
    ])
    expect(await run(manager.terminalFrames(terminal.terminalId))).toEqual([
      { type: "output", seq: 1, data: "hello" },
      { type: "exit", seq: 2, exitCode: 7 },
      { type: "output", seq: 3, data: "after-disconnect" }
    ])
    expect(await run(manager.terminalFrames(terminal.terminalId, 1))).toEqual([
      { type: "exit", seq: 2, exitCode: 7 },
      { type: "output", seq: 3, data: "after-disconnect" }
    ])
    const replacement = await run(
      manager.createTerminal({
        sessionId: "session-2",
        cwd: "/tmp/other",
        cols: 100,
        rows: 40
      })
    )
    expect(replacement.terminalId).not.toBe(terminal.terminalId)
    expect(spawner.requests).toHaveLength(2)

    await run(manager.closeTerminal(terminal.terminalId))
    const stillReplacement = await run(
      manager.createTerminal({
        sessionId: "session-2",
        cwd: "/tmp/other",
        cols: 100,
        rows: 40
      })
    )
    expect(stillReplacement.terminalId).toBe(replacement.terminalId)
    await run(manager.closeTerminal(replacement.terminalId))
    expect(process?.killCount).toBe(1)
    await expect(
      run(manager.connectTerminal(terminal.terminalId, 0, () => undefined))
    ).rejects.toBeInstanceOf(TerminalError)
  })

  it("kills terminals from client close frames and reports missing terminals", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })
    const terminal = await run(
      manager.createTerminal({
        sessionId: "session-3",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    await run(manager.handleClientFrame(terminal.terminalId, closeFrame(1)))
    expect(spawner.processes[0]?.killCount).toBe(1)
    await expect(run(manager.terminalFrames("missing"))).rejects.toBeInstanceOf(TerminalError)
    await expect(run(manager.closeTerminal("missing"))).rejects.toBeInstanceOf(TerminalError)
  })

  it("closes the live terminal for a session and reports sessions without one", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({ spawner })

    // No terminal for the session at all.
    expect(await run(manager.closeTerminalForSession("session-5"))).toBe(false)

    const terminal = await run(
      manager.createTerminal({
        sessionId: "session-5",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    // Live terminal: killed and unregistered, so the next create respawns.
    expect(await run(manager.closeTerminalForSession("session-5"))).toBe(true)
    expect(spawner.processes[0]?.killCount).toBe(1)
    await expect(run(manager.terminalFrames(terminal.terminalId))).rejects.toBeInstanceOf(
      TerminalError
    )
    const replacement = await run(
      manager.createTerminal({
        sessionId: "session-5",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )
    expect(replacement.terminalId).not.toBe(terminal.terminalId)

    // A pty that exited on its own leaves a stale mapping: closing reports
    // false, drops the mapping, and does not double-kill the process.
    spawner.handlers[1]?.onExit(0)
    expect(await run(manager.closeTerminalForSession("session-5"))).toBe(false)
    expect(spawner.processes[1]?.killCount).toBe(0)
    expect(await run(manager.closeTerminalForSession("session-5"))).toBe(false)
  })

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

const inputFrame = (clientSeq: number, data: string): TerminalClientFrame => ({
  type: "input",
  clientId: "test-client",
  clientSeq,
  data
})

const resizeFrame = (clientSeq: number, cols: number, rows: number): TerminalClientFrame => ({
  type: "resize",
  clientId: "test-client",
  clientSeq,
  cols,
  rows
})

const closeFrame = (clientSeq: number): TerminalClientFrame => ({
  type: "close",
  clientId: "test-client",
  clientSeq
})
