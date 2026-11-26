import type { RunningTerminal } from "./frames.js"
import { shellDirectory } from "./shell-directory.js"
import type { TerminalSize } from "./size-arbiter.js"
import type { SavedResume, TerminalSnapshotEntry } from "./types.js"

const decoder = new TextDecoder()

export const RESTORED_TERMINAL_SIZE = { cols: 80, rows: 24 } as const

export const restoredSize = (entry: TerminalSnapshotEntry): TerminalSize => ({
  cols: entry.cols ?? RESTORED_TERMINAL_SIZE.cols,
  rows: entry.rows ?? RESTORED_TERMINAL_SIZE.rows
})

export const snapshotEntry = (
  terminal: RunningTerminal,
  resume: SavedResume | undefined
): TerminalSnapshotEntry => {
  const { cols, rows } = terminal.screen.state()
  const exitCode = terminal.exitFrame?.exitCode
  const cwd = shellDirectory(terminal.screen.pwd())
  return {
    terminalId: terminal.terminalId,
    sessionId: terminal.sessionId,
    nextOutputSeq: terminal.nextOutputSeq,
    closed: terminal.closed,
    external: terminal.external,
    screen: decoder.decode(terminal.screen.reconstruct()),
    cols,
    rows,
    ...(exitCode === undefined ? {} : { exitCode }),
    ...(terminal.launch === undefined ? {} : { launch: terminal.launch }),
    ...(cwd === undefined ? {} : { cwd }),
    ...(resume === undefined ? {} : { resume })
  }
}

export const restoreEntry = (terminal: RunningTerminal, entry: TerminalSnapshotEntry): void => {
  if (entry.screen !== undefined) terminal.screen.write(entry.screen)
  if (entry.closed) {
    terminal.exitFrame = {
      type: "exit",
      seq: entry.nextOutputSeq - 1,
      ...(entry.exitCode === undefined ? {} : { exitCode: entry.exitCode })
    }
  }
  for (const frame of entry.frames ?? []) {
    terminal.frames.push(frame)
    if (frame.type === "output") terminal.screen.write(frame.data)
    if (frame.type === "exit") terminal.exitFrame = frame
  }
}
