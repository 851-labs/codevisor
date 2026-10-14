import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import type {
  Harness,
  HarnessBundledApp,
  HarnessLifecycleState,
  HarnessUpdateInfo
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { FetchLike } from "@codevisor/updater"

export interface HarnessLifecycleEvent {
  readonly kind: "harness.lifecycle.updated"
  readonly subjectId: string
  readonly payload: unknown
}

export interface LifecycleProcess {
  readonly onOutput: (listener: (data: string) => void) => void
  readonly onExit: (listener: (exitCode: number | undefined) => void) => void
  readonly kill: () => void
}

export interface PendingHarnessSetup {
  readonly finish: () => Promise<void>
}

export interface HarnessLifecycleManagerConfig {
  readonly db: CodevisorDatabaseService
  readonly agents: AgentRuntimeService
  readonly terminal?: TerminalManagerService
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  readonly fetchImpl?: FetchLike
  readonly platform?: NodeJS.Platform
  readonly arch?: string
  readonly home?: string
  readonly realpath?: (path: string) => string
  readonly pathExists?: ((path: string) => boolean) | undefined
  readonly spawnShell?: (command: string, env: NodeJS.ProcessEnv) => LifecycleProcess
  readonly applyBundleSwap?: (options: {
    readonly bundlePath: string
    readonly appcastXml: string
  }) => Promise<{ readonly installedVersion: string }>
  readonly readBundleShortVersion?: (bundlePath: string) => Promise<string | undefined>
  readonly now?: () => number
  readonly checkIntervalMs?: number
  readonly checkCacheMs?: number
  readonly operationTimeoutMs?: number
  readonly harnessSetup?: Readonly<
    Record<string, (env: NodeJS.ProcessEnv) => Promise<PendingHarnessSetup | undefined>>
  >
  readonly gateEnabled?: boolean
}

export interface HarnessUpdateCheckOutcome {
  readonly harnessId: string
  readonly info: HarnessUpdateInfo
}

export interface HarnessLifecycleManager {
  readonly beginUninstall: (harnessId: string) => Promise<void>
  readonly decorateHarnesses: (harnesses: ReadonlyArray<Harness>) => Promise<ReadonlyArray<Harness>>
  readonly checkForUpdates: (
    force?: boolean,
    harnessIds?: ReadonlyArray<string>
  ) => Promise<ReadonlyArray<HarnessUpdateCheckOutcome>>
  readonly startPeriodicChecks: () => () => void
  readonly beginInstall: (
    harnessId: string,
    methodId?: string
  ) => Promise<{ readonly terminalId: string }>
  readonly beginUpdate: (harnessId: string) => Promise<{
    readonly queued: boolean
    readonly terminalId?: string
    readonly lifecycle?: HarnessLifecycleState
  }>
  readonly notifyTurnStarted: (harnessId: string) => void
  readonly notifyTurnEnded: (harnessId: string) => void
  readonly isGated: (harnessId: string) => boolean
  readonly bundledAppInfo: (harnessId: string) => Promise<HarnessBundledApp | undefined>
  readonly beginBundledAppUpdate: (harnessId: string) => Promise<void>
  readonly forcePendingUpdate: (harnessId: string) => Promise<void>
  readonly cancelPendingUpdate: (harnessId: string) => Promise<void>
  readonly finishPendingSetup: () => Promise<void>
  readonly reconcileOnStartup: () => Promise<void>
  readonly onGateReleased: (listener: (harnessId: string) => void) => () => void
  readonly subscribe: (listener: (event: HarnessLifecycleEvent) => void) => () => void
}
