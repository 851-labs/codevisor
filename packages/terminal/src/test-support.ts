import type { TerminalClientFrame, TerminalServerFrame } from "@codevisor/api"
import { Effect } from "effect"

import type {
  TerminalError,
  TerminalHandlers,
  TerminalManagerService,
  TerminalProcess,
  TerminalSpawnRequest,
  TerminalSpawner
} from "./index.js"

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

/// The frames a client attaching after `lastOutputSeq` receives as replay.
export const replayedFrames = (
  manager: TerminalManagerService,
  terminalId: string,
  lastOutputSeq = 0
): Effect.Effect<ReadonlyArray<TerminalServerFrame>, TerminalError> => {
  const frames: Array<TerminalServerFrame> = []
  return Effect.map(
    manager.connectTerminal(terminalId, lastOutputSeq, (frame) => frames.push(frame)),
    (disconnect) => {
      disconnect()
      return frames
    }
  )
}

export class FakeProcess implements TerminalProcess {
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

export const makeSpawner = (
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

export const inputFrame = (clientSeq: number, data: string): TerminalClientFrame => ({
  type: "input",
  clientId: "test-client",
  clientSeq,
  data
})

export const resizeFrame = (
  clientSeq: number,
  cols: number,
  rows: number
): TerminalClientFrame => ({
  type: "resize",
  clientId: "test-client",
  clientSeq,
  cols,
  rows
})

export const closeFrame = (clientSeq: number): TerminalClientFrame => ({
  type: "close",
  clientId: "test-client",
  clientSeq
})
