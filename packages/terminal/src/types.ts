import type {
  TerminalClientFrame,
  TerminalCreateRequest,
  TerminalCreateResponse,
  TerminalServerFrame
} from "@codevisor/api"
import type { Effect } from "effect"
import { Schema } from "effect"

export class TerminalError extends Schema.TaggedErrorClass<TerminalError>()("TerminalError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface TerminalProcess {
  readonly write: (data: string) => void
  readonly resize: (cols: number, rows: number) => void
  readonly kill: () => void
}

export interface TerminalSpawnRequest extends TerminalCreateRequest {
  readonly shell: string
  readonly env: NodeJS.ProcessEnv
}

export interface TerminalHandlers {
  readonly onOutput: (data: string) => void
  readonly onExit: (exitCode: number | undefined) => void
}

export interface TerminalSpawner {
  readonly spawn: (
    request: TerminalSpawnRequest,
    handlers: TerminalHandlers
  ) => Effect.Effect<TerminalProcess, TerminalError>
}

export interface TerminalManagerConfig {
  readonly defaultShell?: string
  readonly env?: NodeJS.ProcessEnv
  readonly spawner?: TerminalSpawner
  /// Host platform used to select a terminal name. Injectable for tests.
  readonly platform?: NodeJS.Platform
  /// The effective user's passwd-database shell. Injectable so service-style
  /// environments with no SHELL can be covered without depending on the test
  /// runner's account.
  readonly userShell?: () => string | undefined
  /// Executability check for automatically discovered shell candidates.
  readonly executableExists?: (path: string) => boolean
  /// Override for tests or alternate packages. Production uses the Ghostty
  /// terminfo database shipped beside this package's compiled JavaScript.
  readonly terminfoDirectory?: string
}

/// Caller-facing side of an externally-managed terminal: the caller owns the
/// process and pumps its output/exit through this handle; input, resize, and
/// kill flow back through the `TerminalProcess` supplied at registration.
export interface ExternalTerminalHandle {
  readonly terminalId: string
  readonly response: TerminalCreateResponse
  readonly output: (data: string) => void
  readonly exit: (exitCode?: number) => void
  /// Removes the terminal entirely (frames included) — for terminals that
  /// were never surfaced to a client, so nothing lingers after a short-lived
  /// process ends. Safe to call after `exit`.
  readonly remove: () => void
}

export interface ExternalTerminalConfig {
  readonly sessionId: string
  /// Pipe-fed processes emit bare "\n" line endings; a real terminal renderer
  /// needs "\r\n". Enabled for mirrors/wrappers that read pipes, not PTYs.
  readonly normalizeNewlines?: boolean
}

/// A serializable dump of one terminal's replay state, as captured by
/// `snapshotTerminals` — everything `restoreTerminals` needs to keep
/// scrollback readable and `lastOutputSeq` replay coherent across a host
/// restart. The process itself never survives a restart, so restored
/// terminals are process-less and closed.
export interface TerminalSnapshotEntry {
  readonly terminalId: string
  readonly sessionId: string
  readonly frames: ReadonlyArray<TerminalServerFrame>
  readonly nextOutputSeq: number
  readonly closed: boolean
  readonly external: boolean
}

export interface TerminalSnapshot {
  readonly version: 1
  readonly terminals: ReadonlyArray<TerminalSnapshotEntry>
}

export interface TerminalManagerService {
  readonly createTerminal: (
    request: TerminalCreateRequest,
    envOverrides?: NodeJS.ProcessEnv
  ) => Effect.Effect<TerminalCreateResponse, TerminalError>
  readonly connectTerminal: (
    terminalId: string,
    lastOutputSeq: number,
    sink: (frame: TerminalServerFrame) => void
  ) => Effect.Effect<() => void, TerminalError>
  readonly handleClientFrame: (
    terminalId: string,
    frame: TerminalClientFrame
  ) => Effect.Effect<void, TerminalError>
  readonly terminalFrames: (
    terminalId: string,
    since?: number
  ) => Effect.Effect<ReadonlyArray<TerminalServerFrame>, TerminalError>
  readonly closeTerminal: (terminalId: string) => Effect.Effect<void, TerminalError>
  /// Kills the live terminal for a session (if any), so the next createTerminal
  /// for that session spawns a fresh shell. Returns whether one was closed.
  readonly closeTerminalForSession: (sessionId: string) => Effect.Effect<boolean, TerminalError>
  /// Kills and removes every terminal whose session key starts with `prefix`
  /// (scrollback included). Used when a chat session is archived: its
  /// background-task terminals (`<agentSessionId>:bg:...`) must not keep
  /// processes running. Returns how many terminals were removed.
  readonly closeTerminalsForSessionPrefix: (prefix: string) => Effect.Effect<number, TerminalError>
  /// Registers a terminal whose process the CALLER owns (an agent's background
  /// shell, a mirrored remote process). The manager never spawns or respawns
  /// it: clients attach with `attachOnly` createTerminal requests, and the
  /// terminal remains attachable after exit so its scrollback stays readable.
  readonly registerExternalTerminal: (
    config: ExternalTerminalConfig,
    process: TerminalProcess
  ) => ExternalTerminalHandle
  /// Serializable dump of every terminal's replay buffer. Synchronous so the
  /// server can call it from process exit handlers; frame counts are bounded
  /// per terminal, so the snapshot is bounded too.
  readonly snapshotTerminals: () => TerminalSnapshot
  /// Restores a previous process's snapshot. Restored terminals are closed
  /// and process-less: they replay scrollback (and a synthetic exit frame if
  /// the process was still live at snapshot time) but never accept input.
  /// External terminals reclaim their session mapping so `attachOnly` clients
  /// still reach their scrollback; regular session shells do not, so the next
  /// createTerminal for the session spawns a fresh shell as usual. Terminal
  /// ids that already exist are skipped — call this before serving clients.
  readonly restoreTerminals: (snapshot: TerminalSnapshot) => void
}
