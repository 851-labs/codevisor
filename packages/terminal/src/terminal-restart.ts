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
  prepare: () => RestartLaunch
): void => {
  const queued = makeQueuedProcess()
  context.attachSession(terminal)
  terminal.process = queued
  context.pushFrame(terminal, { type: "output", data: restartPreamble(terminal.screen.state()) })

  const start = (): void => startRestartedProcess(context, terminal, prepare, queued)
  if (context.after === undefined) start()
  else void context.after.then(start, start).catch(() => endRestart(context, terminal))
}

const startRestartedProcess = (
  context: RestartContext,
  terminal: RunningTerminal,
  prepare: () => RestartLaunch,
  queued: QueuedProcess
): void => {
  if (terminal.closed) return

  const launch = prepare()
  terminal.resumeToken = launch.request.resumeToken
  const spawned = context.spawner.spawn(
    launch.request,
    restartedHandlers(context, terminal, launch)
  )
  void Effect.runPromise(spawned).then(
    (process) => adoptRestartedProcess(terminal, queued, process),
    () => endRestart(context, terminal, launch)
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
  launch?: RestartLaunch,
  exitCode?: number
): void => {
  launch?.discard()
  terminal.restoring = undefined
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
  terminal.restoring = undefined
  process.resize(terminal.sizes.size.cols, terminal.sizes.size.rows)
  queued.replayInto(process)
}
