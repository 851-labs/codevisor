import type { RunningTerminal } from "./frames.js"
import {
  makeProgramStatusRecords,
  makeProgramStatusScanner,
  PROGRAM_STATUS_QUERY_REPLY,
  type ProgramStatusRecords,
  type ProgramStatusScanner
} from "./program-status.js"
import { makeShellPrompt, type ShellPrompt } from "./shell-prompt.js"
import { terminalTitleStatus } from "./terminal-title-status.js"
import type { TerminalTitleListener, TerminalTitleStatus } from "./types.js"

export const TITLE_SETTLE_MS = 500

const NO_TITLE: TerminalTitleStatus = { title: undefined, activity: undefined }

const same = (a: TerminalTitleStatus, b: TerminalTitleStatus): boolean =>
  a.title === b.title && a.activity === b.activity

interface TitleState {
  current: TerminalTitleStatus
  published: TerminalTitleStatus
  prompt: ShellPrompt
  scanner: ProgramStatusScanner
  records: ProgramStatusRecords
  timer?: ReturnType<typeof setTimeout>
}

export interface TerminalTitles {
  readonly observe: (terminal: RunningTerminal, data: string) => void
  readonly end: (terminal: RunningTerminal) => void
  readonly subscribe: (listener: TerminalTitleListener) => () => void
}

const observeTitleStatus = (
  terminal: RunningTerminal,
  state: TitleState,
  data: string
): TerminalTitleStatus => {
  state.prompt.observe(data)
  for (const event of state.scanner.scan(data)) {
    if (event.type === "query") {
      terminal.process.write(`\u001b]7501;${PROGRAM_STATUS_QUERY_REPLY}${event.terminator}`)
    } else {
      state.records.apply(event)
    }
  }
  const title =
    state.prompt.running() === false ? NO_TITLE : terminalTitleStatus(terminal.screen.title())
  return { title: title.title, activity: state.records.summary() ?? title.activity }
}

export const makeTerminalTitles = (): TerminalTitles => {
  const states = new WeakMap<RunningTerminal, TitleState>()
  const listeners = new Set<TerminalTitleListener>()

  const publish = (terminal: RunningTerminal, state: TitleState, status: TerminalTitleStatus) => {
    if (same(status, state.published)) return
    state.published = status
    for (const listener of listeners) listener(terminal.sessionId, status)
  }

  return {
    observe: (terminal, data) => {
      if (terminal.closed) return
      const state = states.get(terminal) ?? {
        current: NO_TITLE,
        published: NO_TITLE,
        prompt: makeShellPrompt(),
        scanner: makeProgramStatusScanner(),
        records: makeProgramStatusRecords()
      }
      states.set(terminal, state)
      const status = observeTitleStatus(terminal, state, data)
      if (same(status, state.current)) return
      state.current = status
      clearTimeout(state.timer)
      state.timer = setTimeout(() => publish(terminal, state, state.current), TITLE_SETTLE_MS)
      state.timer.unref()
    },
    end: (terminal) => {
      const state = states.get(terminal)
      if (state === undefined) return
      states.delete(terminal)
      clearTimeout(state.timer)
      publish(terminal, state, NO_TITLE)
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}
