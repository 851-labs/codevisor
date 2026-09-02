import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import type {
  Harness,
  HarnessBundledApp,
  HarnessInstallMethod,
  HarnessLifecycleState,
  HarnessUpdateInfo
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { FetchLike } from "@codevisor/updater"

/// Harness lifecycle manager — mirrors makeHarnessAuthManager's shape:
/// factory + injected config + listener set bridged to the server's event
/// fanout. It owns update *detection* (periodic latest-version checks,
/// persistence, decoration), install/update execution, and the
/// update-when-idle gate.

export interface HarnessLifecycleEvent {
  readonly kind: "harness.lifecycle.updated"
  readonly subjectId: string
  readonly payload: unknown
}

/// A spawned install/update command, abstracted for tests.
export interface LifecycleProcess {
  readonly onOutput: (listener: (data: string) => void) => void
  readonly onExit: (listener: (exitCode: number | undefined) => void) => void
  readonly kill: () => void
}

export interface HarnessLifecycleManagerConfig {
  readonly db: CodevisorDatabaseService
  readonly agents: AgentRuntimeService
  /// Server-owned terminals: install/update output streams through an
  /// external terminal so clients can attach ("Show Output"). Absent
  /// (embedded runtimes, tests without terminals), operations are refused.
  readonly terminal?: TerminalManagerService
  /// Login-shell environment for spawns and method availability; defaults to
  /// the process env. Typically `() => resolveShellEnv()`.
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  /// Test overrides.
  readonly fetchImpl?: FetchLike
  readonly platform?: NodeJS.Platform
  readonly arch?: string
  readonly home?: string
  readonly realpath?: (path: string) => string
  /// Spawns a shell command for an install/update run; defaults to
  /// `$SHELL -lc` (falling back to /bin/sh) with the resolved env.
  readonly spawnShell?: (command: string, env: NodeJS.ProcessEnv) => LifecycleProcess
  /// Performs the verified app-bundle swap; defaults to applyAppBundleSwap.
  /// Injected in tests.
  readonly applyBundleSwap?: (options: {
    readonly bundlePath: string
    readonly appcastXml: string
  }) => Promise<{ readonly installedVersion: string }>
  /// Reads an app bundle's CFBundleShortVersionString (appBundle origin);
  /// defaults to `plutil -extract … raw`.
  readonly readBundleShortVersion?: (bundlePath: string) => Promise<string | undefined>
  readonly now?: () => number
  /// Periodic check cadence; default 6h. The check also runs shortly after
  /// startPeriodicChecks() with a small jitter so boot isn't delayed.
  readonly checkIntervalMs?: number
  /// Suppresses re-checking within this window unless forced; default 5min.
  readonly checkCacheMs?: number
  /// Kills a hung install/update run; default 10min.
  readonly operationTimeoutMs?: number
  /// After an updater exits successfully, keep the lifecycle in `updating`
  /// while the installed binary catches up to the requested target. Defaults
  /// to 2min, with a 500ms local-version probe cadence.
  readonly updateVerificationTimeoutMs?: number
  readonly updateVerificationPollIntervalMs?: number
  /// Kill switch for the when-idle prompt gate (CODEVISOR_HARNESS_UPDATE_GATE=0):
  /// updates still run, prompts just dispatch on the old binary.
  readonly gateEnabled?: boolean
}

export interface HarnessUpdateCheckOutcome {
  readonly harnessId: string
  readonly info: HarnessUpdateInfo
}

export interface HarnessLifecycleManager {
  /// Merges persisted update knowledge, live operation state, and resolved
  /// install methods onto discovered harnesses.
  readonly decorateHarnesses: (harnesses: ReadonlyArray<Harness>) => Promise<ReadonlyArray<Harness>>
  /// Checks latest versions for every ready harness with update sources.
  /// Never throws; offline checks leave the last known state in place.
  readonly checkForUpdates: (force?: boolean) => Promise<ReadonlyArray<HarnessUpdateCheckOutcome>>
  readonly startPeriodicChecks: () => () => void
  /// Install methods for one harness, resolved against the machine (which
  /// package managers exist) with the preference order brew > curl > npm.
  readonly installMethods: (harnessId: string) => Promise<ReadonlyArray<HarnessInstallMethod>>
  /// Runs the vendor install command in an attachable terminal. Refuses when
  /// an operation is already running for the harness.
  readonly beginInstall: (
    harnessId: string,
    methodId?: string
  ) => Promise<{ readonly terminalId: string }>
  /// Runs the origin-matched update (native self-updater, reinstall, or app
  /// bundle swap). With chats mid-turn on the harness, arms a durable pending
  /// update instead and returns `queued: true` — it executes when the last
  /// turn ends (or on forcePendingUpdate).
  readonly beginUpdate: (harnessId: string) => Promise<{
    readonly queued: boolean
    readonly terminalId?: string
    /// Present on current servers so clients can hand their optimistic
    /// spinner directly to the authoritative lifecycle without an event race.
    readonly lifecycle?: HarnessLifecycleState
  }>
  /// Turn accounting from the prompt dispatcher: drives "is this harness
  /// busy" and triggers pending updates when the last turn ends.
  readonly notifyTurnStarted: (harnessId: string) => void
  readonly notifyTurnEnded: (harnessId: string) => void
  /// Whether prompt dispatch for the harness is held (an armed update is
  /// executing right now). Always false with the gate kill switch off.
  readonly isGated: (harnessId: string) => boolean
  /// Dual-install support: when a harness's binary comes from the user's own
  /// install (brew/npm/…) but a desktop app also bundles a copy, this reports
  /// the app's version and update state against its Sparkle feed. Computed on
  /// demand (the detail sheet's lazy fetch); undefined when no bundled app
  /// exists or off darwin.
  readonly bundledAppInfo: (harnessId: string) => Promise<HarnessBundledApp | undefined>
  /// Runs the verified bundle swap for the bundled app — the explicit
  /// "update the app too" action. Immediate (no when-idle gate): the swap is
  /// safe beside running processes, which keep their old inodes.
  readonly beginBundledAppUpdate: (harnessId: string) => Promise<void>
  /// "Update Now" on a queued update — skips the idle wait.
  readonly forcePendingUpdate: (harnessId: string) => Promise<void>
  readonly cancelPendingUpdate: (harnessId: string) => Promise<void>
  /// Called once at boot: interrupted running updates become failures (never
  /// a surviving gate), still-armed pending updates re-run once idle.
  readonly reconcileOnStartup: () => Promise<void>
  /// Fired when a gate releases (update finished, failed, or timed out) so
  /// the dispatcher re-drains held sessions.
  readonly onGateReleased: (listener: (harnessId: string) => void) => () => void
  readonly subscribe: (listener: (event: HarnessLifecycleEvent) => void) => () => void
}
