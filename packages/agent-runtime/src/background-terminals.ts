/// Server-owned terminals for agent background processes.
///
/// Providers register long-running agent processes (backgrounded shells, ACP
/// client terminals, mirrored codex commands) under a stable *terminal key*;
/// the host application backs the registry with its terminal manager so
/// clients can attach to the process's live output as a regular terminal.
/// The key rides on `BackgroundTask.terminalKey` wire snapshots, which is how
/// clients learn a task has an attachable terminal.

/// Controls the registry can exercise over the caller's process. All optional:
/// a mirror of a process someone else owns supports none of them.
export interface ExternalTerminalControls {
  readonly write?: (data: string) => void
  readonly resize?: (cols: number, rows: number) => void
  readonly kill?: () => void
}

/// The caller-facing stream for one registered terminal: pump output and the
/// final exit through it. `remove` deletes a terminal that was never surfaced
/// to a client (short-lived command, nothing to keep scrollback for).
export interface ExternalTerminalStream {
  readonly output: (data: string) => void
  readonly exit: (exitCode?: number) => void
  readonly remove: () => void
}

export interface BackgroundTerminalRegistry {
  readonly register: (key: string, controls: ExternalTerminalControls) => ExternalTerminalStream
}

/// Everything a provider needs to surface background processes as terminals.
export interface BackgroundTerminalIntegration {
  readonly registry: BackgroundTerminalRegistry
  /// Rewrites a background shell command so its output tees through the
  /// external-terminal host while stdout/stderr still reach the agent
  /// unchanged. Absent when the host has no out-of-process bridge (the
  /// Claude provider then leaves background Bash untouched).
  readonly wrapCommand?: (key: string, command: string) => string
  /// How long a command must stay alive before it is promoted to a
  /// background-task terminal tab (ACP/codex providers — commands there have
  /// no explicit "background" flag, so liveness is the signal).
  readonly promotionDelayMs?: number
}

export const DEFAULT_PROMOTION_DELAY_MS = 10_000

/// Terminal keys are namespaced under the runtime session key so they never
/// collide with the session's own interactive terminals (bare session UUID /
/// `<session>:<pane>` keys) and remain per-task unique.
export const backgroundTerminalKey = (sessionKey: string, taskId: string): string =>
  `${sessionKey}:bg:${taskId}`
