import type { RunningTerminal } from "./frames.js"
import { makeShellPrompt, type ShellPrompt } from "./shell-prompt.js"
import { terminalTitleStatus } from "./terminal-title-status.js"
import type { TerminalTitleListener, TerminalTitleStatus } from "./types.js"

/// How long a title must hold before listeners hear it. Programs animate
/// titles (Claude Code cycles a spinner glyph every ~100 ms while working);
/// only the title they settle on is worth persisting and syncing.
export const TITLE_SETTLE_MS = 500

const NO_TITLE: TerminalTitleStatus = { title: undefined, activity: undefined }

const same = (a: TerminalTitleStatus, b: TerminalTitleStatus): boolean =>
  a.title === b.title && a.activity === b.activity

interface TitleState {
  /// The title on the terminal's screen right now, as read for display.
  current: TerminalTitleStatus
  /// The last title listeners heard.
  published: TerminalTitleStatus
  prompt: ShellPrompt
  timer?: ReturnType<typeof setTimeout>
}

export interface TerminalTitles {
  /// Call after `data` reaches the terminal's screen.
  readonly observe: (terminal: RunningTerminal, data: string) => void
  /// The terminal exited or left the manager: its title no longer applies.
  readonly end: (terminal: RunningTerminal) => void
  readonly subscribe: (listener: TerminalTitleListener) => () => void
}

/// Trailing debounce of each terminal's title, keyed by its session key (what
/// workspace panes store as their resource id). It settles the title as read
/// for display (activity glyph dropped) together with that activity, so a
/// spinner animating a working agent's title changes nothing and restarts no
/// timer: the agent publishes once when it starts and once when it stops.
/// While the shell waits at its prompt the terminal has no title (see
/// `ShellPrompt`): the pane shows its own name until a command runs.
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
        prompt: makeShellPrompt()
      }
      states.set(terminal, state)
      state.prompt.observe(data)
      const status =
        state.prompt.running() === false ? NO_TITLE : terminalTitleStatus(terminal.screen.title())
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
