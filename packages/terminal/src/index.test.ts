import type {
  TerminalHandlers,
  TerminalProcess,
  TerminalSpawnRequest,
  TerminalSpawner
} from "./index.js"
import { Effect } from "effect"
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

describe("@herdman/terminal", () => {
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
      manager.connectTerminal(terminal.terminalId, (frame) => frames.push(frame))
    )
    disconnect()

    expect(frames).toEqual([{ type: "output", data: "booting" }, { type: "exit" }])
    await expect(
      run(manager.handleClientFrame(terminal.terminalId, { type: "input", data: "ignored" }))
    ).rejects.toBeInstanceOf(TerminalError)
  })

  it("handles input, resize, live output, exit, replay, and removal", async () => {
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
      manager.connectTerminal(terminal.terminalId, (frame) => firstSink.push(frame))
    )

    await run(manager.handleClientFrame(terminal.terminalId, { type: "input", data: "ls\n" }))
    await run(
      manager.handleClientFrame(terminal.terminalId, { type: "resize", cols: 140, rows: 50 })
    )
    spawner.handlers[0]?.onOutput("hello")
    spawner.handlers[0]?.onExit(7)
    disconnect()
    spawner.handlers[0]?.onOutput("after-disconnect")

    const process = spawner.processes[0]
    expect(spawner.requests[0]).toMatchObject({ shell: "/bin/bash", env: { PATH: "/bin" } })
    expect(process?.writes).toEqual(["ls\n"])
    expect(process?.resizes).toEqual([[140, 50]])
    expect(firstSink).toEqual([
      { type: "output", data: "hello" },
      { type: "exit", exitCode: 7 }
    ])
    expect(await run(manager.terminalFrames(terminal.terminalId))).toEqual([
      { type: "output", data: "hello" },
      { type: "exit", exitCode: 7 },
      { type: "output", data: "after-disconnect" }
    ])

    await run(manager.closeTerminal(terminal.terminalId))
    expect(process?.killCount).toBe(1)
    await expect(
      run(manager.connectTerminal(terminal.terminalId, () => undefined))
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

    await run(manager.handleClientFrame(terminal.terminalId, { type: "close" }))
    expect(spawner.processes[0]?.killCount).toBe(1)
    await expect(run(manager.terminalFrames("missing"))).rejects.toBeInstanceOf(TerminalError)
    await expect(run(manager.closeTerminal("missing"))).rejects.toBeInstanceOf(TerminalError)
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
        manager.connectTerminal(terminal.terminalId, () => {
          throw cause
        })
      )
    ).rejects.toBeInstanceOf(TerminalError)
  })
})
