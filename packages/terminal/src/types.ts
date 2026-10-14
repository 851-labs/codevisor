import type {
  TerminalClientFrame,
  TerminalCreateRequest,
  TerminalCreateResponse,
  TerminalServerFrame,
  TerminalActivity
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
  readonly stop?: () => Promise<void>
  readonly isShellInForeground?: () => boolean
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
  readonly platform?: NodeJS.Platform
  readonly userShell?: () => string | undefined
  readonly executableExists?: (path: string) => boolean
  readonly ghosttyResourcesDirectory?: string
}

export interface TerminalTitleStatus {
  readonly title: string | undefined
  readonly activity: TerminalActivity | undefined
}

export type TerminalTitleListener = (sessionId: string, status: TerminalTitleStatus) => void

export interface ExternalTerminalHandle {
  readonly terminalId: string
  readonly response: TerminalCreateResponse
  readonly output: (data: string) => void
  readonly exit: (exitCode?: number) => void
  readonly remove: () => void
}

export interface ExternalTerminalConfig {
  readonly sessionId: string
  readonly normalizeNewlines?: boolean
}

export interface TerminalSnapshotEntry {
  readonly terminalId: string
  readonly sessionId: string
  readonly nextOutputSeq: number
  readonly closed: boolean
  readonly external: boolean
  readonly screen?: string
  readonly cols?: number
  readonly rows?: number
  readonly exitCode?: number
  readonly frames?: ReadonlyArray<TerminalServerFrame>
}

export interface TerminalSnapshot {
  readonly version: 1 | 2 | 3
  readonly terminals: ReadonlyArray<TerminalSnapshotEntry>
}

export type TerminalScreenFormat = "text" | "vt"

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
  readonly closeTerminal: (terminalId: string) => Effect.Effect<void, TerminalError>
  readonly closeTerminalForSession: (sessionId: string) => Effect.Effect<boolean, TerminalError>
  readonly closeTerminalsForSessionPrefix: (prefix: string) => Effect.Effect<number, TerminalError>
  readonly registerExternalTerminal: (
    config: ExternalTerminalConfig,
    process: TerminalProcess
  ) => ExternalTerminalHandle
  readonly snapshotTerminals: () => TerminalSnapshot
  readonly restoreTerminals: (snapshot: TerminalSnapshot) => void
  readonly readScreen: (
    terminalId: string,
    format: TerminalScreenFormat
  ) => Effect.Effect<string, TerminalError>
  readonly outputRevision: () => number
  readonly subscribeTitles: (listener: TerminalTitleListener) => () => void
  readonly releaseClient: (terminalId: string, clientId: string) => void
}
