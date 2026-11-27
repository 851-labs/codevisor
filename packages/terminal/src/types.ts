import type {
  TerminalClientFrame,
  TerminalCreateRequest,
  TerminalCreateResponse,
  TerminalServerFrame,
  TerminalActivity
} from "@codevisor/api"
import type { ProcessIdentity } from "@codevisor/processes"
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
  readonly tree?: TerminalProcessTree
}

export interface TerminalProcessTree {
  readonly member: (pid: number) => Promise<ProcessIdentity | undefined>
  readonly recentlyAlive: (process: ProcessIdentity, withinMs: number) => boolean
  readonly cwd: (pid: number) => Promise<string | undefined>
}

export interface TerminalSpawnRequest extends TerminalCreateRequest {
  readonly shell: string
  readonly env: NodeJS.ProcessEnv
  readonly resumeToken?: string
  readonly resumesProgram?: boolean
}

export interface TerminalLaunch {
  readonly cwd: string
  readonly shell?: string | undefined
  readonly args?: ReadonlyArray<string> | undefined
}

export interface SavedResume {
  readonly argv: ReadonlyArray<string>
  readonly cwd?: string | undefined
  readonly cwdFromReport: boolean
  readonly uid: number
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
  readonly launchEnvironment?: (env: NodeJS.ProcessEnv) => NodeJS.ProcessEnv
  readonly restoreAfter?: Promise<unknown>
  readonly spawner?: TerminalSpawner
  readonly platform?: NodeJS.Platform
  readonly userShell?: () => string | undefined
  readonly executableExists?: (path: string) => boolean
  readonly ghosttyResourcesDirectory?: string
  readonly userId?: number
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
  readonly launch?: TerminalLaunch
  readonly cwd?: string
  readonly resume?: SavedResume
}

export interface TerminalSnapshot {
  readonly version: 1 | 2 | 3 | 4
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
  readonly subscribeResumes: (listener: () => void) => () => void
  readonly releaseClient: (terminalId: string, clientId: string) => void
}
