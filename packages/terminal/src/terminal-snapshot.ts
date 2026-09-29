import type { RunningTerminal } from "./frames.js"
import type { TerminalSnapshotEntry } from "./types.js"

const decoder = new TextDecoder()

/// Screen size restored terminals get when an older snapshot recorded none.
export const RESTORED_TERMINAL_SIZE = { cols: 80, rows: 24 } as const

/// A terminal's persistent form: its screen and scrollback reconstructed as
/// VT text rather than raw output, so the file stays bounded by scrollback
/// lines however long the terminal ran.
export const snapshotEntry = (terminal: RunningTerminal): TerminalSnapshotEntry => {
  const { cols, rows } = terminal.screen.state()
  const exitCode = terminal.exitFrame?.exitCode
  return {
    terminalId: terminal.terminalId,
    sessionId: terminal.sessionId,
    nextOutputSeq: terminal.nextOutputSeq,
    closed: terminal.closed,
    external: terminal.external,
    screen: decoder.decode(terminal.screen.reconstruct()),
    cols,
    rows,
    ...(exitCode === undefined ? {} : { exitCode })
  }
}

/// Rebuilds a restored terminal's screen (and, from version 1 files, its
/// replay frames). A version 2 terminal keeps no frames: every client is
/// resynced from the screen.
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
