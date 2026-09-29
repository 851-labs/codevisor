import type { TerminalServerFrame } from "@codevisor/api"

import type { RunningTerminal } from "./frames.js"
import { createVtTerminal, type VtTerminal } from "./vt/ghostty-vt.js"

const decoder = new TextDecoder()

/// The server's authoritative copy of a terminal's screen. While no client is
/// attached, it also answers the queries programs send (device attributes,
/// cursor position reports) so agent-driven and background shells don't
/// stall waiting for a renderer; attached renderers answer for themselves.
export const createTerminalScreen = (
  terminal: () => RunningTerminal | undefined,
  size: { readonly cols: number; readonly rows: number }
): VtTerminal =>
  createVtTerminal({
    cols: size.cols,
    rows: size.rows,
    onReply: (reply) => {
      const current = terminal()
      if (current === undefined || current.closed || current.sinks.size > 0) return
      current.process.write(decoder.decode(reply))
    }
  })

/// True when the replay buffer still holds every frame after
/// `lastOutputSeq`, so the client can be caught up byte for byte.
export const replayCovers = (terminal: RunningTerminal, lastOutputSeq: number): boolean =>
  // An empty buffer (restored from a snapshot) covers only a client that
  // already saw everything.
  lastOutputSeq >= (terminal.frames.firstSeq ?? terminal.nextOutputSeq) - 1

/// Frames that bring a client from any state to the terminal's current one
/// when the replay buffer no longer reaches back to its cursor: a reset plus
/// a reconstruction of the screen and scrollback, followed by the exit if
/// the process already ended.
export const resyncFrames = (terminal: RunningTerminal): Array<TerminalServerFrame> => {
  const head = terminal.nextOutputSeq - 1
  const frames: Array<TerminalServerFrame> = [
    { type: "output", seq: head, data: decoder.decode(terminal.screen.reconstruct()), reset: true }
  ]
  if (terminal.exitFrame !== undefined) frames.push({ ...terminal.exitFrame, seq: head })
  return frames
}
