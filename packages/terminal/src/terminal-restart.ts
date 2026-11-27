import { Effect } from "effect"

import type { RunningTerminal, TerminalFramePayload } from "./frames.js"
import {
  makeQueuedProcess,
  restartPreamble,
  type QueuedProcess,
  type RestartLaunch
} from "./terminal-restart-launch.js"
import type { TerminalHandlers, TerminalProcess, TerminalSpawner } from "./types.js"

export interface RestartContext {
  readonly spawner: TerminalSpawner
  readonly after?: Promise<unknown> | undefined
  readonly pushFrame: (terminal: RunningTerminal, frame: TerminalFramePayload) => void
  readonly markExited: (terminal: RunningTerminal) => void
  readonly attachSession: (terminal: RunningTerminal) => void
}

export const restartTerminal = (
  context: RestartContext,
  terminal: RunningTerminal,
  launch: RestartLaunch
): void => {
  const queued = makeQueuedProcess()
  context.attachSession(terminal)
  terminal.process = queued
  terminal.resumeToken = launch.request.resumeToken
  context.pushFrame(terminal, { type: "output", data: restartPreamble(terminal.screen.state()) })

  const start = (): void => startRestartedProcess(context, terminal, launch, queued)
  if (context.after === undefined) start()
  else void context.after.then(start, start)
}

const startRestartedProcess = (
  context: RestartContext,
  terminal: RunningTerminal,
  launch: RestartLaunch,
  queued: QueuedProcess
): void => {
  if (terminal.closed) {
    launch.discard()
    return
  }

  const spawned = context.spawner.spawn(
    launch.request,
    restartedHandlers(context, terminal, launch)
  )
  void Effect.runPromise(spawned).then(
    (process) => adoptRestartedProcess(terminal, queued, process),
    () => endRestart(context, terminal, launch, undefined)
  )
}

const restartedHandlers = (
  context: RestartContext,
  terminal: RunningTerminal,
  launch: RestartLaunch
): TerminalHandlers => ({
  onOutput: (data) => context.pushFrame(terminal, { type: "output", data }),
  onExit: (exitCode) => endRestart(context, terminal, launch, exitCode)
})

const endRestart = (
  context: RestartContext,
  terminal: RunningTerminal,
  launch: RestartLaunch,
  exitCode: number | undefined
): void => {
  launch.discard()
  context.pushFrame(
    terminal,
    exitCode === undefined ? { type: "exit" } : { type: "exit", exitCode }
  )
  context.markExited(terminal)
}

const adoptRestartedProcess = (
  terminal: RunningTerminal,
  queued: QueuedProcess,
  process: TerminalProcess
): void => {
  if (terminal.closed) {
    process.kill()
    return
  }
  terminal.process = process
  process.resize(terminal.sizes.size.cols, terminal.sizes.size.rows)
  queued.replayInto(process)
}
