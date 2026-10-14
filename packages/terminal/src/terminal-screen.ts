import type { TerminalServerFrame } from "@codevisor/api"

import type { RunningTerminal } from "./frames.js"
import { createVtTerminal, type VtTerminal } from "./vt/ghostty-vt.js"

const decoder = new TextDecoder()

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

export const replayCovers = (terminal: RunningTerminal, lastOutputSeq: number): boolean =>
  lastOutputSeq >= (terminal.frames.firstSeq ?? terminal.nextOutputSeq) - 1

export const resyncFrames = (terminal: RunningTerminal): Array<TerminalServerFrame> => {
  const head = terminal.nextOutputSeq - 1
  const frames: Array<TerminalServerFrame> = [
    { type: "output", seq: head, data: decoder.decode(terminal.screen.reconstruct()), reset: true }
  ]
  if (terminal.exitFrame !== undefined) frames.push({ ...terminal.exitFrame, seq: head })
  return frames
}
