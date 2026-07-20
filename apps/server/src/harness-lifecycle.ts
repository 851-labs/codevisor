import {
  locateExecutableOnPath,
  type AgentRuntimeService,
  type HarnessDefinition,
  type HarnessInstallMethodSpec,
  type HarnessUpdateSource,
  type InstallOrigin
} from "@codevisor/agent-runtime"
import type {
  Harness,
  HarnessBundledApp,
  HarnessInstallMethod,
  HarnessLifecycleState,
  HarnessUpdateInfo
} from "@codevisor/api"
import type { CodevisorDatabaseService, HarnessPendingUpdateRecord } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { execFile, spawn } from "node:child_process"
import { basename, join } from "node:path"
import { promisify } from "node:util"
import { Effect } from "effect"
import { applyAppBundleSwap } from "./app-bundle-swap.js"
import { parseAppcast, selectLatestAppcastItem } from "./appcast.js"
import {
  checkBrewLatest,
  checkGithubLatest,
  checkNpmLatest,
  detectInstallOrigin,
  isNewerVersion,
  type FetchLike,
  type LatestVersionResult
} from "./harness-update-sources.js"

const execFileAsync = promisify(execFile)

/// Harness lifecycle manager — mirrors makeHarnessAuthManager's shape:
/// factory + injected config + listener set bridged to the server's event
/// fanout. This first slice owns update *detection* (periodic latest-version
/// checks, persistence, decoration); install/update execution and the
/// update-when-idle gate arrive in later slices.

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
  readonly beginUpdate: (
    harnessId: string
  ) => Promise<{ readonly queued: boolean; readonly terminalId?: string }>
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

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

/// "/Applications/ChatGPT.app/Contents/Resources/codex" → the .app bundle.
export const appBundlePath = (binaryPath: string): string | undefined => {
  const index = binaryPath.indexOf(".app/")
  return index === -1 ? undefined : binaryPath.slice(0, index + 4)
}

/// Preference order among *available* methods.
const METHOD_PREFERENCE: ReadonlyArray<HarnessInstallMethodSpec["kind"]> = ["brew", "curl", "npm"]

const installCommand = (spec: HarnessInstallMethodSpec): string => {
  switch (spec.kind) {
    case "brew":
      return `brew install ${spec.cask === true ? "--cask " : ""}${spec.formula ?? ""}`.trim()
    case "npm":
      return `npm install -g ${spec.packageName ?? ""}`.trim()
    case "curl":
      return spec.command ?? ""
  }
}

/// The reinstall-style update command for a method (brew upgrades in place,
/// npm reinstalls @latest, curl reruns the vendor script).
const upgradeCommand = (spec: HarnessInstallMethodSpec): string => {
  switch (spec.kind) {
    case "brew":
      return `brew upgrade ${spec.cask === true ? "--cask " : ""}${spec.formula ?? ""}`.trim()
    case "npm":
      return `npm install -g ${spec.packageName ?? ""}@latest`.trim()
    case "curl":
      return spec.command ?? ""
  }
}

/// A method is runnable when its prerequisite tool exists on the PATH.
const methodPrerequisite = (kind: HarnessInstallMethodSpec["kind"]): string =>
  kind === "brew" ? "brew" : kind === "npm" ? "npm" : "curl"

const defaultSpawnShell = (command: string, env: NodeJS.ProcessEnv): LifecycleProcess => {
  const shell = env.SHELL !== undefined && env.SHELL !== "" ? env.SHELL : "/bin/sh"
  const child = spawn(shell, ["-lc", command], {
    // Its own group so a timeout kill takes worker descendants with it.
    detached: process.platform !== "win32",
    env,
    stdio: ["ignore", "pipe", "pipe"]
  })
  const outputListeners = new Set<(data: string) => void>()
  const exitListeners = new Set<(exitCode: number | undefined) => void>()
  const forward = (chunk: unknown): void => {
    const data = String(chunk)
    for (const listener of outputListeners) listener(data)
  }
  child.stdout.on("data", forward)
  child.stderr.on("data", forward)
  child.once("error", (cause) => {
    forward(`${cause.message}\n`)
    for (const listener of exitListeners) listener(undefined)
  })
  child.once("exit", (code) => {
    for (const listener of exitListeners) listener(code ?? undefined)
  })
  return {
    kill: () => {
      try {
        if (process.platform !== "win32" && child.pid !== undefined) {
          process.kill(-child.pid, "SIGKILL")
        } else {
          child.kill("SIGKILL")
        }
      } catch {
        // Already gone.
      }
    },
    onExit: (listener) => exitListeners.add(listener),
    onOutput: (listener) => outputListeners.add(listener)
  }
}

const defaultReadBundleShortVersion = async (bundlePath: string): Promise<string | undefined> => {
  try {
    const { stdout } = await execFileAsync(
      "plutil",
      ["-extract", "CFBundleShortVersionString", "raw", join(bundlePath, "Contents", "Info.plist")],
      { timeout: 5_000 }
    )
    const version = stdout.trim()
    return version.length > 0 ? version : undefined
  } catch {
    return undefined
  }
}

export const makeHarnessLifecycleManager = (
  config: HarnessLifecycleManagerConfig
): HarnessLifecycleManager => {
  const listeners = new Set<(event: HarnessLifecycleEvent) => void>()
  const fetchImpl = config.fetchImpl ?? (fetch as FetchLike)
  const now = config.now ?? (() => Date.now())
  const platform = config.platform ?? process.platform
  const arch = config.arch ?? process.arch
  const checkCacheMs = config.checkCacheMs ?? 5 * 60_000
  const checkIntervalMs = config.checkIntervalMs ?? 6 * 60 * 60_000
  const readBundleShortVersion = config.readBundleShortVersion ?? defaultReadBundleShortVersion

  /// Last persisted state per harness, hydrated from the db on first use so
  /// clients see last-known knowledge before the first live check.
  let states: Map<string, HarnessUpdateInfo> | undefined
  let lastCheckAt = 0
  let inFlight: Promise<ReadonlyArray<HarnessUpdateCheckOutcome>> | undefined

  const emit = (event: HarnessLifecycleEvent): void => {
    for (const listener of listeners) listener(event)
  }

  const loadStates = async (): Promise<Map<string, HarnessUpdateInfo>> => {
    if (states !== undefined) return states
    const loaded = new Map<string, HarnessUpdateInfo>()
    try {
      for (const record of await run(config.db.listHarnessUpdateStates)) {
        loaded.set(record.harnessId, record.info)
      }
    } catch {
      // A fresh database simply starts empty.
    }
    states = loaded
    return loaded
  }

  const checkSource = async (source: HarnessUpdateSource): Promise<LatestVersionResult> => {
    switch (source.check.kind) {
      case "npm":
        return checkNpmLatest(source.check.packageName, source.check.distTag ?? "latest", fetchImpl)
      case "brew":
        return checkBrewLatest(source.check.formula, fetchImpl)
      case "github":
        return checkGithubLatest(source.check.repo, fetchImpl)
      case "sparkle": {
        const url =
          arch === "x64" && source.check.appcastUrlX64 !== undefined
            ? source.check.appcastUrlX64
            : source.check.appcastUrl
        try {
          const response = await fetchImpl(url, { signal: AbortSignal.timeout(10_000) })
          if (!response.ok) return {}
          const item = selectLatestAppcastItem(parseAppcast(await response.text()))
          return item?.shortVersion === undefined
            ? {}
            : { channel: "app", latestVersion: item.shortVersion }
        } catch {
          return {}
        }
      }
    }
  }

  const matchSource = (
    definition: HarnessDefinition,
    origin: InstallOrigin
  ): HarnessUpdateSource | undefined => {
    const sources = definition.update?.sources ?? []
    return sources.find((source) => source.when === origin) ?? sources.find((s) => s.when === "any")
  }

  const checkHarness = async (
    definition: HarnessDefinition,
    harness: Harness
  ): Promise<HarnessUpdateCheckOutcome | undefined> => {
    const path = harness.readiness.path
    if (harness.readiness.state !== "ready" || path === undefined) return undefined
    const origin = detectInstallOrigin(path, {
      ...(config.home === undefined ? {} : { home: config.home }),
      ...(config.realpath === undefined ? {} : { realpath: config.realpath })
    })
    const source = matchSource(definition, origin)
    if (source === undefined) return undefined
    // App-bundle installs update via the app, so both sides of the version
    // comparison must be app versions — never the CLI's own --version, whose
    // channel runs ahead of the stable lines.
    let installedVersion = harness.readiness.version
    if (source.apply.kind === "appBundleSwap") {
      if (platform !== "darwin") return undefined
      const bundle = source.apply.bundlePath ?? appBundlePath(path)
      if (bundle === undefined) return undefined
      installedVersion = await readBundleShortVersion(bundle)
    }
    const latest = await checkSource(source)
    const updateAvailable =
      installedVersion !== undefined &&
      latest.latestVersion !== undefined &&
      isNewerVersion(latest.latestVersion, installedVersion)
    const info: HarnessUpdateInfo = {
      updateAvailable,
      installOrigin: origin,
      source: source.check.kind,
      checkedAt: new Date(now()).toISOString(),
      ...(installedVersion === undefined ? {} : { installedVersion }),
      ...(latest.latestVersion === undefined ? {} : { latestVersion: latest.latestVersion }),
      ...(latest.channel === undefined ? {} : { channel: latest.channel })
    }
    return { harnessId: definition.id, info }
  }

  const meaningfullyChanged = (
    previous: HarnessUpdateInfo | undefined,
    next: HarnessUpdateInfo
  ): boolean =>
    previous === undefined ||
    previous.updateAvailable !== next.updateAvailable ||
    previous.latestVersion !== next.latestVersion ||
    previous.installedVersion !== next.installedVersion

  const checkForUpdates = async (
    force = false
  ): Promise<ReadonlyArray<HarnessUpdateCheckOutcome>> => {
    if (inFlight !== undefined) return inFlight
    if (!force && now() - lastCheckAt < checkCacheMs) return []
    inFlight = (async () => {
      const current = await loadStates()
      const harnesses = await run(config.agents.discoverHarnesses)
      const outcomes: Array<HarnessUpdateCheckOutcome> = []
      await Promise.all(
        config.agents.catalog
          .filter((definition) => definition.update !== undefined)
          .map(async (definition) => {
            const harness = harnesses.find((candidate) => candidate.id === definition.id)
            if (harness === undefined) return
            try {
              const outcome = await checkHarness(definition, harness)
              if (outcome === undefined) return
              outcomes.push(outcome)
              const previous = current.get(outcome.harnessId)
              current.set(outcome.harnessId, outcome.info)
              await run(
                config.db.setHarnessUpdateState({
                  harnessId: outcome.harnessId,
                  info: outcome.info
                })
              ).catch(() => undefined)
              if (meaningfullyChanged(previous, outcome.info)) {
                emit({
                  kind: "harness.lifecycle.updated",
                  payload: { harnessId: outcome.harnessId, updateInfo: outcome.info },
                  subjectId: outcome.harnessId
                })
              }
            } catch {
              // One harness's failed check must not block the others.
            }
          })
      )
      lastCheckAt = now()
      return outcomes
    })().finally(() => {
      inFlight = undefined
    })
    return inFlight
  }

  // ── Install/update execution ─────────────────────────────────────────

  const spawnShell = config.spawnShell ?? defaultSpawnShell
  const operationTimeoutMs = config.operationTimeoutMs ?? 10 * 60_000
  const resolveEnvUncached = config.resolveEnv ?? (() => Promise.resolve(process.env))
  /// resolveShellEnv spawns a login shell — expensive. One shared resolution
  /// serves every install-method lookup for a minute; concurrent callers
  /// share the in-flight promise. Invalidated after installs/updates so the
  /// next lookup sees freshly installed package managers.
  let envCache: { readonly at: number; readonly promise: Promise<NodeJS.ProcessEnv> } | undefined
  const resolveEnv = (): Promise<NodeJS.ProcessEnv> => {
    if (envCache === undefined || now() - envCache.at > 60_000) {
      envCache = {
        at: now(),
        promise: resolveEnvUncached().catch(() => process.env)
      }
    }
    return envCache.promise
  }
  const invalidateEnvCache = (): void => {
    envCache = undefined
  }
  /// Live operation (installing/updating) or terminal failure per harness.
  /// Success clears the entry (idle). In-memory on purpose: an interrupted
  /// operation dies with the process and readiness re-probes the truth.
  const operations = new Map<string, HarnessLifecycleState>()

  const setOperation = (harnessId: string, state: HarnessLifecycleState | undefined): void => {
    if (state === undefined) operations.delete(harnessId)
    else operations.set(harnessId, state)
    emit({
      kind: "harness.lifecycle.updated",
      payload: {
        harnessId,
        lifecycle: state ?? { phase: "idle" },
        ...(states?.get(harnessId) === undefined ? {} : { updateInfo: states.get(harnessId) })
      },
      subjectId: harnessId
    })
  }

  const definitionOrThrow = (harnessId: string): HarnessDefinition => {
    const definition = config.agents.catalog.find((candidate) => candidate.id === harnessId)
    if (definition === undefined) throw new Error(`Unknown harness: ${harnessId}`)
    return definition
  }

  const resolveInstallMethods = async (
    definition: HarnessDefinition
  ): Promise<ReadonlyArray<HarnessInstallMethod>> => {
    const specs = definition.installMethods ?? []
    if (specs.length === 0) return []
    const env = await resolveEnv()
    const methods = specs.map((spec) => ({
      available: locateExecutableOnPath(methodPrerequisite(spec.kind), env) !== undefined,
      command: installCommand(spec),
      id: spec.kind,
      kind: spec.kind,
      label: spec.kind === "brew" ? "Homebrew" : spec.kind === "npm" ? "npm" : "Installer script",
      recommended: false,
      spec
    }))
    const recommended = METHOD_PREFERENCE.map((kind) =>
      methods.find((method) => method.kind === kind && method.available)
    ).find((method) => method !== undefined)
    return methods.map(({ spec: _spec, ...method }) => ({
      ...method,
      recommended: method.id === recommended?.id
    }))
  }

  /// Shared runner: spawns `command` in an attachable external terminal,
  /// tracks phase, and settles to idle (success) or failed (exit/timeout).
  const runOperation = async (options: {
    readonly harnessId: string
    readonly phase: "installing" | "updating"
    readonly command: string
    readonly extraEnv?: Readonly<Record<string, string>>
    readonly methodId?: string
    readonly targetVersion?: string
    readonly onSettled?: (success: boolean) => void
  }): Promise<{ readonly terminalId: string }> => {
    const terminal = config.terminal
    if (terminal === undefined) {
      throw new Error("Harness install/update is unavailable on this server")
    }
    const runningPhase = operations.get(options.harnessId)?.phase
    if (runningPhase === "installing" || runningPhase === "updating") {
      throw new Error(`An operation is already running for ${options.harnessId}`)
    }
    const env = { ...(await resolveEnv()), ...options.extraEnv }
    const handle = terminal.registerExternalTerminal(
      { normalizeNewlines: true, sessionId: `harness-lifecycle:${options.harnessId}` },
      { kill: () => child.kill(), resize: () => {}, write: () => {} }
    )
    handle.output(`$ ${options.command}\r\n`)
    const child = spawnShell(options.command, env)
    let outputTail = ""
    child.onOutput((data) => {
      handle.output(data)
      outputTail = (outputTail + data).slice(-2_000)
    })
    let settled = false
    const settle = async (exitCode: number | undefined, timedOut: boolean): Promise<void> => {
      if (settled) return
      settled = true
      clearTimeout(timeout)
      handle.exit(exitCode)
      if (exitCode === 0 && !timedOut) {
        // Re-resolve PATH + re-probe versions so readiness reflects the new
        // binary, then refresh update knowledge so badges clear promptly.
        invalidateEnvCache()
        await run(config.agents.refreshEnvironment).catch(() => undefined)
        lastCheckAt = 0
        await checkForUpdates(true).catch(() => undefined)
        setOperation(options.harnessId, undefined)
        options.onSettled?.(true)
        return
      }
      const reason = timedOut
        ? `Timed out after ${Math.round(operationTimeoutMs / 60_000)} minutes`
        : `Exited with status ${exitCode ?? "unknown"}`
      setOperation(options.harnessId, {
        error: `${reason}\n${outputTail.trim()}`.trim(),
        phase: "failed",
        terminalId: handle.terminalId,
        ...(options.methodId === undefined ? {} : { methodId: options.methodId }),
        ...(options.targetVersion === undefined ? {} : { targetVersion: options.targetVersion })
      })
      options.onSettled?.(false)
    }
    const timeout = setTimeout(() => {
      child.kill()
      void settle(undefined, true)
    }, operationTimeoutMs)
    timeout.unref()
    child.onExit((exitCode) => void settle(exitCode, false))
    setOperation(options.harnessId, {
      phase: options.phase,
      startedAt: new Date(now()).toISOString(),
      terminalId: handle.terminalId,
      ...(options.methodId === undefined ? {} : { methodId: options.methodId }),
      ...(options.targetVersion === undefined ? {} : { targetVersion: options.targetVersion })
    })
    return { terminalId: handle.terminalId }
  }

  const beginInstall = async (
    harnessId: string,
    methodId?: string
  ): Promise<{ readonly terminalId: string }> => {
    const definition = definitionOrThrow(harnessId)
    const specs = definition.installMethods ?? []
    const methods = await resolveInstallMethods(definition)
    const method =
      methodId === undefined
        ? methods.find((candidate) => candidate.recommended)
        : methods.find((candidate) => candidate.id === methodId)
    if (method === undefined || !method.available) {
      throw new Error(`No runnable install method for ${harnessId}`)
    }
    const spec = specs.find((candidate) => candidate.kind === method.kind)
    if (spec === undefined) throw new Error(`No runnable install method for ${harnessId}`)
    return runOperation({
      command: installCommand(spec),
      harnessId,
      methodId: method.id,
      phase: "installing"
    })
  }

  // ── When-idle gate ───────────────────────────────────────────────────

  const gateEnabled = config.gateEnabled ?? process.env.CODEVISOR_HARNESS_UPDATE_GATE !== "0"
  const gateListeners = new Set<(harnessId: string) => void>()
  /// In-memory mirror of harness_pending_updates, hydrated by reconcile.
  const pendingUpdates = new Map<string, HarnessPendingUpdateRecord>()
  /// In-flight turn count per harness (from the prompt dispatcher).
  const busyCounts = new Map<string, number>()

  const isHarnessBusy = (harnessId: string): boolean => (busyCounts.get(harnessId) ?? 0) > 0

  const releaseGate = (harnessId: string): void => {
    pendingUpdates.delete(harnessId)
    void run(config.db.clearHarnessPendingUpdate(harnessId)).catch(() => undefined)
    for (const listener of gateListeners) listener(harnessId)
  }

  /// Transitions an armed update to running and executes it. The gate holds
  /// only while the update actually runs; every settle path releases it.
  const runPendingUpdate = async (harnessId: string): Promise<void> => {
    const pending = pendingUpdates.get(harnessId)
    if (pending === undefined || pending.state === "running") return
    const record: HarnessPendingUpdateRecord = {
      ...pending,
      startedAt: new Date(now()).toISOString(),
      state: "running",
      timeoutAt: new Date(now() + operationTimeoutMs).toISOString()
    }
    pendingUpdates.set(harnessId, record)
    await run(config.db.setHarnessPendingUpdate(record)).catch(() => undefined)
    try {
      await executeUpdateNow(harnessId, () => releaseGate(harnessId))
    } catch (cause) {
      setOperation(harnessId, {
        error: cause instanceof Error ? cause.message : String(cause),
        phase: "failed",
        ...(pending.targetVersion === undefined ? {} : { targetVersion: pending.targetVersion })
      })
      releaseGate(harnessId)
    }
  }

  const beginUpdate = async (
    harnessId: string
  ): Promise<{ readonly queued: boolean; readonly terminalId?: string }> => {
    definitionOrThrow(harnessId)
    if (gateEnabled && isHarnessBusy(harnessId) && !pendingUpdates.has(harnessId)) {
      // Chats are mid-turn on this harness: arm a durable pending update that
      // executes when the last turn ends.
      const targetVersion = (await loadStates()).get(harnessId)?.latestVersion
      const record: HarnessPendingUpdateRecord = {
        harnessId,
        requestedAt: new Date(now()).toISOString(),
        state: "pending",
        ...(targetVersion === undefined ? {} : { targetVersion })
      }
      pendingUpdates.set(harnessId, record)
      await run(config.db.setHarnessPendingUpdate(record)).catch(() => undefined)
      setOperation(harnessId, {
        phase: "pendingUpdate",
        startedAt: record.requestedAt,
        ...(targetVersion === undefined ? {} : { targetVersion })
      })
      return { queued: true }
    }
    return executeUpdateNow(harnessId)
  }

  const executeUpdateNow = async (
    harnessId: string,
    onSettled?: (success: boolean) => void
  ): Promise<{ readonly queued: boolean; readonly terminalId?: string }> => {
    const definition = definitionOrThrow(harnessId)
    const harnesses = await run(config.agents.discoverHarnesses)
    const harness = harnesses.find((candidate) => candidate.id === harnessId)
    const path = harness?.readiness.path
    if (harness === undefined || harness.readiness.state !== "ready" || path === undefined) {
      throw new Error(`${harnessId} is not installed`)
    }
    const origin = detectInstallOrigin(path, {
      ...(config.home === undefined ? {} : { home: config.home }),
      ...(config.realpath === undefined ? {} : { realpath: config.realpath })
    })
    const source = matchSource(definition, origin)
    if (source === undefined) throw new Error(`${harnessId} has no update source`)
    const targetVersion = (await loadStates()).get(harnessId)?.latestVersion
    switch (source.apply.kind) {
      case "selfUpdate": {
        const { terminalId } = await runOperation({
          command: [path, ...source.apply.args].join(" "),
          harnessId,
          phase: "updating",
          ...(source.apply.env === undefined ? {} : { extraEnv: source.apply.env }),
          ...(targetVersion === undefined ? {} : { targetVersion }),
          ...(onSettled === undefined ? {} : { onSettled })
        })
        return { queued: false, terminalId }
      }
      case "reinstall": {
        const spec = (definition.installMethods ?? []).find(
          (candidate) =>
            candidate.kind === (origin === "brew" ? "brew" : origin === "curl" ? "curl" : "npm")
        )
        if (spec === undefined)
          throw new Error(`${harnessId} has no reinstall method for ${origin}`)
        const { terminalId } = await runOperation({
          command: upgradeCommand(spec),
          harnessId,
          methodId: spec.kind,
          phase: "updating",
          ...(targetVersion === undefined ? {} : { targetVersion }),
          ...(onSettled === undefined ? {} : { onSettled })
        })
        return { queued: false, terminalId }
      }
      case "appBundleSwap": {
        if (platform !== "darwin" || origin !== "appBundle") {
          throw new Error(`${definition.name} updates via its desktop app`)
        }
        const bundle = source.apply.bundlePath ?? appBundlePath(path)
        if (bundle === undefined) {
          throw new Error(`${definition.name}'s app bundle location is unknown`)
        }
        if (source.check.kind !== "sparkle") {
          throw new Error(`${definition.name}'s update feed is not a Sparkle appcast`)
        }
        startBundleSwap({
          appcastUrl: sparkleFeedUrl(source.check),
          bundle,
          harnessId,
          ...(targetVersion === undefined ? {} : { targetVersion }),
          ...(onSettled === undefined ? {} : { onSettled })
        })
        return { queued: false }
      }
    }
  }

  /// The effective Sparkle feed for a check spec: arch-matched, with an env
  /// override so end-to-end rehearsal can point at a fixture feed.
  const sparkleFeedUrl = (check: { appcastUrl: string; appcastUrlX64?: string }): string =>
    process.env.CODEVISOR_CODEX_APPCAST_URL ??
    (arch === "x64" && check.appcastUrlX64 !== undefined ? check.appcastUrlX64 : check.appcastUrl)

  /// Fires the verified bundle swap as a background operation on the
  /// harness's lifecycle state. Shared by the app-bundle-origin update path
  /// and the dual-install "update the app too" flow.
  const startBundleSwap = (options: {
    readonly harnessId: string
    readonly bundle: string
    readonly appcastUrl: string
    readonly targetVersion?: string
    readonly onSettled?: (success: boolean) => void
  }): void => {
    const { appcastUrl, bundle, harnessId, onSettled, targetVersion } = options
    const runningPhase = operations.get(harnessId)?.phase
    if (runningPhase === "installing" || runningPhase === "updating") {
      throw new Error(`An operation is already running for ${harnessId}`)
    }
    const applySwap = config.applyBundleSwap ?? applyAppBundleSwap
    setOperation(harnessId, {
      phase: "updating",
      startedAt: new Date(now()).toISOString(),
      ...(targetVersion === undefined ? {} : { targetVersion })
    })
    void (async () => {
      try {
        const response = await fetchImpl(appcastUrl, {
          signal: AbortSignal.timeout(30_000)
        })
        if (!response.ok) throw new Error(`Update feed unavailable (HTTP ${response.status})`)
        await applySwap({ appcastXml: await response.text(), bundlePath: bundle })
        await run(config.agents.refreshEnvironment).catch(() => undefined)
        lastCheckAt = 0
        await checkForUpdates(true).catch(() => undefined)
        setOperation(harnessId, undefined)
        onSettled?.(true)
      } catch (cause) {
        setOperation(harnessId, {
          error: cause instanceof Error ? cause.message : String(cause),
          phase: "failed",
          ...(targetVersion === undefined ? {} : { targetVersion })
        })
        onSettled?.(false)
      }
    })()
  }

  // ── Dual-install bundled app ─────────────────────────────────────────

  const bundledAppSource = (definition: HarnessDefinition): HarnessUpdateSource | undefined =>
    definition.update?.sources.find(
      (source) => source.apply.kind === "appBundleSwap" && source.check.kind === "sparkle"
    )

  const locateBundledBinary = async (
    definition: HarnessDefinition
  ): Promise<string | undefined> => {
    const env = await resolveEnv()
    for (const candidate of definition.fallbackPaths ?? []) {
      const path = locateExecutableOnPath(candidate, env)
      if (path !== undefined) return path
    }
    return undefined
  }

  const bundledAppTarget = async (
    harnessId: string
  ): Promise<
    | {
        readonly bundle: string
        readonly check: { readonly appcastUrl: string; readonly appcastUrlX64?: string }
      }
    | undefined
  > => {
    if (platform !== "darwin") return undefined
    const definition = definitionOrThrow(harnessId)
    const source = bundledAppSource(definition)
    if (source === undefined || source.check.kind !== "sparkle") return undefined
    const binary = await locateBundledBinary(definition)
    if (binary === undefined) return undefined
    const bundle =
      (source.apply.kind === "appBundleSwap" ? source.apply.bundlePath : undefined) ??
      appBundlePath(binary)
    if (bundle === undefined) return undefined
    return { bundle, check: source.check }
  }

  const bundledAppInfo = async (harnessId: string): Promise<HarnessBundledApp | undefined> => {
    const target = await bundledAppTarget(harnessId)
    if (target === undefined) return undefined
    const installedVersion = await readBundleShortVersion(target.bundle)
    const latest = await checkSource({
      apply: { kind: "appBundleSwap" },
      check: { kind: "sparkle", ...target.check },
      when: "appBundle"
    })
    return {
      appName: basename(target.bundle).replace(/\.app$/, ""),
      bundlePath: target.bundle,
      updateAvailable:
        installedVersion !== undefined &&
        latest.latestVersion !== undefined &&
        isNewerVersion(latest.latestVersion, installedVersion),
      ...(installedVersion === undefined ? {} : { installedVersion }),
      ...(latest.latestVersion === undefined ? {} : { latestVersion: latest.latestVersion })
    }
  }

  const beginBundledAppUpdate = async (harnessId: string): Promise<void> => {
    const target = await bundledAppTarget(harnessId)
    if (target === undefined) {
      throw new Error(`${harnessId} has no bundled desktop app`)
    }
    const latest = await checkSource({
      apply: { kind: "appBundleSwap" },
      check: { kind: "sparkle", ...target.check },
      when: "appBundle"
    })
    startBundleSwap({
      appcastUrl: sparkleFeedUrl(target.check),
      bundle: target.bundle,
      harnessId,
      ...(latest.latestVersion === undefined ? {} : { targetVersion: latest.latestVersion })
    })
  }

  const decorateHarnesses = async (
    harnesses: ReadonlyArray<Harness>
  ): Promise<ReadonlyArray<Harness>> => {
    const current = await loadStates()
    return Promise.all(
      harnesses.map(async (harness) => {
        const info = current.get(harness.id)
        const lifecycle = operations.get(harness.id)
        // Install methods are only rendered for harnesses that aren't
        // installed — skip the availability resolution for ready ones so the
        // list stays cheap (lazy: the machine's package managers are checked
        // only where an Install button could appear).
        const definition =
          harness.readiness.state === "ready"
            ? undefined
            : config.agents.catalog.find((candidate) => candidate.id === harness.id)
        const methods =
          definition === undefined ? [] : await resolveInstallMethods(definition).catch(() => [])
        return {
          ...harness,
          ...(info === undefined ? {} : { updateInfo: info }),
          ...(lifecycle === undefined ? {} : { lifecycle }),
          ...(methods.length === 0 ? {} : { installMethods: methods })
        }
      })
    )
  }

  const startPeriodicChecks = (): (() => void) => {
    // Jittered first run so boot-time work (env refresh, auth probes) wins
    // the contention; then a steady cadence.
    const initialDelay = 20_000 + Math.floor(Math.random() * 40_000)
    const initial = setTimeout(() => {
      void checkForUpdates(true).catch(() => undefined)
    }, initialDelay)
    initial.unref()
    const interval = setInterval(() => {
      void checkForUpdates(true).catch(() => undefined)
    }, checkIntervalMs)
    interval.unref()
    return () => {
      clearTimeout(initial)
      clearInterval(interval)
    }
  }

  const notifyTurnStarted = (harnessId: string): void => {
    busyCounts.set(harnessId, (busyCounts.get(harnessId) ?? 0) + 1)
  }

  const notifyTurnEnded = (harnessId: string): void => {
    const next = Math.max(0, (busyCounts.get(harnessId) ?? 0) - 1)
    if (next === 0) busyCounts.delete(harnessId)
    else busyCounts.set(harnessId, next)
    if (next === 0 && pendingUpdates.get(harnessId)?.state === "pending") {
      void runPendingUpdate(harnessId).catch(() => undefined)
    }
  }

  const isGated = (harnessId: string): boolean =>
    gateEnabled && pendingUpdates.get(harnessId)?.state === "running"

  const forcePendingUpdate = async (harnessId: string): Promise<void> => {
    if (pendingUpdates.get(harnessId)?.state !== "pending") {
      throw new Error(`No pending update for ${harnessId}`)
    }
    await runPendingUpdate(harnessId)
  }

  const cancelPendingUpdate = async (harnessId: string): Promise<void> => {
    if (pendingUpdates.get(harnessId)?.state !== "pending") {
      throw new Error(`No pending update for ${harnessId}`)
    }
    pendingUpdates.delete(harnessId)
    await run(config.db.clearHarnessPendingUpdate(harnessId)).catch(() => undefined)
    setOperation(harnessId, undefined)
  }

  const reconcileOnStartup = async (): Promise<void> => {
    let records: ReadonlyArray<HarnessPendingUpdateRecord>
    try {
      records = await run(config.db.listHarnessPendingUpdates)
    } catch {
      return
    }
    for (const record of records) {
      if (record.state === "running") {
        // The update (and any gate) died with the previous process — never
        // resurrect a gate; report the interruption instead.
        await run(config.db.clearHarnessPendingUpdate(record.harnessId)).catch(() => undefined)
        setOperation(record.harnessId, {
          error: "Interrupted by a server restart",
          phase: "failed",
          ...(record.targetVersion === undefined ? {} : { targetVersion: record.targetVersion })
        })
        continue
      }
      // Still-armed updates survive the restart; the chats that blocked them
      // did not, so run shortly after boot settles.
      pendingUpdates.set(record.harnessId, record)
      setOperation(record.harnessId, {
        phase: "pendingUpdate",
        startedAt: record.requestedAt,
        ...(record.targetVersion === undefined ? {} : { targetVersion: record.targetVersion })
      })
      const kickoff = setTimeout(() => {
        if (!isHarnessBusy(record.harnessId)) {
          void runPendingUpdate(record.harnessId).catch(() => undefined)
        }
      }, 15_000)
      kickoff.unref()
    }
  }

  return {
    beginBundledAppUpdate,
    beginInstall,
    beginUpdate,
    bundledAppInfo,
    cancelPendingUpdate,
    checkForUpdates,
    decorateHarnesses,
    forcePendingUpdate,
    installMethods: async (harnessId) => resolveInstallMethods(definitionOrThrow(harnessId)),
    isGated,
    notifyTurnEnded,
    notifyTurnStarted,
    onGateReleased: (listener) => {
      gateListeners.add(listener)
      return () => gateListeners.delete(listener)
    },
    reconcileOnStartup,
    startPeriodicChecks,
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}
