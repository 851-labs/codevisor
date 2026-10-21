import { stripVTControlCharacters } from "node:util"

import {
  locateExecutableOnPath,
  type HarnessDefinition,
  type HarnessInstallMethodSpec
} from "@codevisor/agent-runtime"
import type { HarnessInstallMethod, HarnessLifecycleState } from "@codevisor/api"
import type { ExternalTerminalHandle, TerminalManagerService } from "@codevisor/terminal"
import { applyAppBundleSwap, isNewerVersion } from "@codevisor/updater"

import type { HarnessLifecycleCore } from "./harness-lifecycle-core.js"
import type { HarnessUpdateDetection } from "./harness-lifecycle-detection.js"
import { installCommand, METHOD_PREFERENCE, run } from "./harness-lifecycle-support.js"
import type { HarnessLifecycleManagerConfig, LifecycleProcess } from "./harness-lifecycle-types.js"

export interface RunOperationOptions {
  readonly harnessId: string
  readonly phase: "installing" | "updating" | "uninstalling"
  readonly command: string
  readonly extraEnv?: Readonly<Record<string, string>>
  readonly methodId?: string
  readonly targetVersion?: string
  readonly onSettled?: (success: boolean) => void
  readonly verify?: () => Promise<void>
}

export interface StartBundleSwapOptions {
  readonly harnessId: string
  readonly bundle: string
  readonly appcastUrl: string
  readonly targetVersion?: string
  readonly onSettled?: (success: boolean) => void
  readonly recordsHarnessVersion?: boolean
}

export interface StartedOperation {
  readonly lifecycle: HarnessLifecycleState
  readonly terminalId: string
}

export const makeHarnessOperationRunner = (
  core: HarnessLifecycleCore,
  detection: HarnessUpdateDetection
) => {
  const {
    config,
    definitionOrThrow,
    fetchImpl,
    invalidateEnvCache,
    now,
    operationTimeoutMs,
    operations,
    platform,
    resolveEnv,
    setOperation,
    spawnShell
  } = core
  const { checkForUpdatesFresh, recordVerifiedInstalledVersion, waitForInstalledTarget } = detection

  const resolveInstallMethods = async (
    definition: HarnessDefinition
  ): Promise<ReadonlyArray<HarnessInstallMethod>> => {
    const specs = definition.installMethods ?? []
    if (specs.length === 0) return []

    const env = await resolveEnv()
    const methods = specs.map((spec) => describeInstallMethod(spec, env))
    const recommended = recommendedMethod(methods)
    return methods.map(({ spec: _spec, ...method }) => ({
      ...method,
      recommended: method.id === recommended?.id
    }))
  }

  const runOperation = async (options: RunOperationOptions): Promise<StartedOperation> => {
    const terminal = config.terminal
    if (terminal === undefined) {
      throw new Error("Harness install/update is unavailable on this server")
    }
    if (operationInFlight(options)) {
      throw new Error(`An operation is already running for ${options.harnessId}`)
    }

    core.startingOperations.add(options.harnessId)
    try {
      const env = { ...(await resolveEnv()), ...options.extraEnv }
      return startOperation(terminal, env, options)
    } finally {
      core.startingOperations.delete(options.harnessId)
    }
  }

  const beginInstall = async (
    harnessId: string,
    methodId?: string
  ): Promise<{ readonly terminalId: string }> => {
    const definition = definitionOrThrow(harnessId)
    const specs = definition.installMethods ?? []
    const methods = await resolveInstallMethods(definition)
    const method = chosenMethod(methods, methodId)
    if (!isRunnable(method)) throw noRunnableInstallMethod(harnessId)

    const spec = specs.find((candidate) => candidate.kind === method.kind)
    if (spec === undefined) throw noRunnableInstallMethod(harnessId)

    return runOperation({
      command: installCommand(spec),
      harnessId,
      methodId: method.id,
      phase: "installing"
    })
  }

  const startBundleSwap = (options: StartBundleSwapOptions): HarnessLifecycleState => {
    const {
      appcastUrl,
      bundle,
      harnessId,
      onSettled,
      recordsHarnessVersion = true,
      targetVersion
    } = options
    if (isInstallingOrUpdating(operations.get(harnessId)?.phase)) {
      throw new Error(`An operation is already running for ${harnessId}`)
    }

    const applySwap = config.applyBundleSwap ?? applyAppBundleSwap
    const lifecycle: HarnessLifecycleState = {
      phase: "updating",
      startedAt: new Date(now()).toISOString(),
      ...operationTags({ targetVersion })
    }
    setOperation(harnessId, lifecycle)
    void swapBundle({
      appcastUrl,
      applySwap,
      bundle,
      harnessId,
      onSettled,
      recordsHarnessVersion,
      targetVersion
    })
    return lifecycle
  }

  const describeInstallMethod = (
    spec: HarnessInstallMethodSpec,
    env: NodeJS.ProcessEnv
  ): DescribedInstallMethod => ({
    available: !caskUnsupported(spec) && locateExecutableOnPath(spec.kind, env) !== undefined,
    command: installCommand(spec),
    id: spec.kind,
    kind: spec.kind,
    label: methodLabel(spec.kind),
    recommended: false,
    spec
  })

  const caskUnsupported = (spec: HarnessInstallMethodSpec): boolean =>
    spec.kind === "brew" && spec.cask === true && platform !== "darwin"

  const operationInFlight = (options: RunOperationOptions): boolean => {
    const runningPhase = operations.get(options.harnessId)?.phase
    return (
      core.startingOperations.has(options.harnessId) ||
      isRunningPhase(runningPhase) ||
      blockedByUninstall(options)
    )
  }

  const blockedByUninstall = (options: RunOperationOptions): boolean =>
    options.phase !== "uninstalling" && core.uninstallRequests.has(options.harnessId)

  const startOperation = (
    terminal: TerminalManagerService,
    env: NodeJS.ProcessEnv,
    options: RunOperationOptions
  ): StartedOperation => {
    const handle = terminal.registerExternalTerminal(
      { normalizeNewlines: true, sessionId: `harness-lifecycle:${options.harnessId}` },
      { kill: () => child.kill(), resize: () => {}, write: () => {} }
    )
    handle.output(`$ ${options.command}\r\n`)
    const child = spawnShell(options.command, env)
    const outputTail = mirrorOutput(child, handle)
    settleOnExit(child, { handle, options, outputTail })

    const lifecycle = runningLifecycle(options, handle.terminalId)
    setOperation(options.harnessId, lifecycle)
    return { lifecycle, terminalId: handle.terminalId }
  }

  const runningLifecycle = (
    options: RunOperationOptions,
    terminalId: string
  ): HarnessLifecycleState => ({
    phase: options.phase,
    startedAt: new Date(now()).toISOString(),
    terminalId,
    ...operationTags(options)
  })

  const settleOnExit = (child: LifecycleProcess, operation: OperationRun): void => {
    const { options } = operation
    let settled = false
    const settle = async (exitCode: number | undefined, timedOut: boolean): Promise<void> => {
      if (settled) return
      settled = true
      stopWatching(operation, timeout, exitCode)
      if (!exitedCleanly(exitCode, timedOut)) {
        failOperation(operation, exitFailure(exitCode, timedOut, operationTimeoutMs))
        return
      }

      try {
        invalidateEnvCache()
        await options.verify?.()
        let installedVersion: string | undefined
        if (awaitsTargetVersion(options)) {
          installedVersion = await waitForInstalledTarget(options.harnessId, options.targetVersion)
        }
        if (installedVersion === undefined) await refreshEnvironmentQuietly()
        await checkForUpdatesFresh()
        if (installedVersion !== undefined) {
          await recordVerifiedInstalledVersion(options.harnessId, installedVersion)
        }
        if (options.phase !== "uninstalling") await core.finishSetup(options.harnessId)
        succeedOperation(options)
      } catch (cause) {
        failOperation(operation, errorMessage(cause))
      }
    }
    const timeout = killAfterTimeout(child, () => void settle(undefined, true))
    child.onExit((exitCode) => void settle(exitCode, false))
  }

  const killAfterTimeout = (
    child: LifecycleProcess,
    onTimeout: () => void
  ): ReturnType<typeof setTimeout> => {
    const timeout = setTimeout(() => {
      child.kill()
      onTimeout()
    }, operationTimeoutMs)
    timeout.unref()
    return timeout
  }

  const succeedOperation = (options: RunOperationOptions): void => {
    setOperation(options.harnessId, undefined)
    options.onSettled?.(true)
  }

  const failOperation = (operation: OperationRun, reason: string): void => {
    const { handle, options, outputTail } = operation
    setOperation(options.harnessId, {
      error: `${reason}\n${stripVTControlCharacters(outputTail()).trim()}`.trim(),
      phase: "failed",
      terminalId: handle.terminalId,
      ...operationTags(options)
    })
    options.onSettled?.(false)
  }

  const swapBundle = async (swap: BundleSwap): Promise<void> => {
    const {
      appcastUrl,
      applySwap,
      bundle,
      harnessId,
      onSettled,
      recordsHarnessVersion,
      targetVersion
    } = swap
    try {
      const response = await fetchImpl(appcastUrl, {
        signal: AbortSignal.timeout(APPCAST_TIMEOUT_MS)
      })
      if (!response.ok) throw new Error(`Update feed unavailable (HTTP ${response.status})`)

      const result = await applySwap({ appcastXml: await response.text(), bundlePath: bundle })
      if (installedBehindTarget(targetVersion, result)) {
        throw new Error(
          `Bundle swap installed ${result.installedVersion}; expected ${targetVersion}`
        )
      }

      await refreshEnvironmentQuietly()
      await checkForUpdatesFresh()
      if (recordsHarnessVersion) {
        await recordVerifiedInstalledVersion(harnessId, result.installedVersion)
      }
      await core.finishSetup(harnessId)
      setOperation(harnessId, undefined)
      onSettled?.(true)
    } catch (cause) {
      setOperation(harnessId, {
        error: errorMessage(cause),
        phase: "failed",
        ...operationTags({ targetVersion })
      })
      onSettled?.(false)
    }
  }

  const refreshEnvironmentQuietly = () =>
    run(config.agents.refreshEnvironment).catch(() => undefined)

  return { beginInstall, resolveInstallMethods, runOperation, startBundleSwap }
}

export type HarnessOperationRunner = ReturnType<typeof makeHarnessOperationRunner>

interface DescribedInstallMethod extends HarnessInstallMethod {
  readonly spec: HarnessInstallMethodSpec
}

interface OperationRun {
  readonly handle: ExternalTerminalHandle
  readonly options: RunOperationOptions
  readonly outputTail: () => string
}

interface BundleSwap {
  readonly appcastUrl: string
  readonly applySwap: NonNullable<HarnessLifecycleManagerConfig["applyBundleSwap"]>
  readonly bundle: string
  readonly harnessId: string
  readonly onSettled: ((success: boolean) => void) | undefined
  readonly recordsHarnessVersion: boolean
  readonly targetVersion: string | undefined
}

interface OperationTagSource {
  readonly methodId?: string | undefined
  readonly targetVersion?: string | undefined
}

interface OperationTags {
  readonly methodId?: string
  readonly targetVersion?: string
}

const OUTPUT_TAIL_LENGTH = 2_000
const APPCAST_TIMEOUT_MS = 30_000
const MINUTE_MS = 60_000

const methodLabel = (kind: HarnessInstallMethodSpec["kind"]): string => {
  if (kind === "brew") return "Homebrew"
  if (kind === "curl") return "Installer script"
  return kind
}

const recommendedMethod = (
  methods: ReadonlyArray<DescribedInstallMethod>
): DescribedInstallMethod | undefined =>
  methods.find(isMarkedRecommended) ?? preferredAvailableMethod(methods)

const isMarkedRecommended = (method: DescribedInstallMethod): boolean =>
  method.spec.recommended === true && method.available

const preferredAvailableMethod = (
  methods: ReadonlyArray<DescribedInstallMethod>
): DescribedInstallMethod | undefined =>
  METHOD_PREFERENCE.map((kind) =>
    methods.find((method) => method.kind === kind && method.available)
  ).find((method) => method !== undefined)

const chosenMethod = (
  methods: ReadonlyArray<HarnessInstallMethod>,
  methodId: string | undefined
): HarnessInstallMethod | undefined => {
  if (methodId === undefined) return methods.find((candidate) => candidate.recommended)
  return methods.find((candidate) => candidate.id === methodId)
}

const isRunnable = (method: HarnessInstallMethod | undefined): method is HarnessInstallMethod =>
  method !== undefined && method.available

const noRunnableInstallMethod = (harnessId: string): Error =>
  new Error(`No runnable install method for ${harnessId}`)

const isInstallingOrUpdating = (phase: HarnessLifecycleState["phase"] | undefined): boolean =>
  phase === "installing" || phase === "updating"

const isRunningPhase = (phase: HarnessLifecycleState["phase"] | undefined): boolean =>
  isInstallingOrUpdating(phase) || phase === "uninstalling"

const mirrorOutput = (child: LifecycleProcess, handle: ExternalTerminalHandle): (() => string) => {
  let tail = ""
  child.onOutput((data) => {
    handle.output(data)
    tail = (tail + data).slice(-OUTPUT_TAIL_LENGTH)
  })
  return () => tail
}

const stopWatching = (
  operation: OperationRun,
  timeout: ReturnType<typeof setTimeout>,
  exitCode: number | undefined
): void => {
  clearTimeout(timeout)
  operation.handle.exit(exitCode)
}

const operationTags = (options: OperationTagSource): OperationTags => ({
  ...(options.methodId === undefined ? {} : { methodId: options.methodId }),
  ...(options.targetVersion === undefined ? {} : { targetVersion: options.targetVersion })
})

const exitedCleanly = (exitCode: number | undefined, timedOut: boolean): boolean =>
  exitCode === 0 && !timedOut

const exitFailure = (
  exitCode: number | undefined,
  timedOut: boolean,
  timeoutMs: number
): string => {
  if (timedOut) return `Timed out after ${Math.round(timeoutMs / MINUTE_MS)} minutes`
  return `Exited with status ${exitCode ?? "unknown"}`
}

const awaitsTargetVersion = (
  options: RunOperationOptions
): options is RunOperationOptions & { readonly targetVersion: string } =>
  options.phase === "updating" && options.targetVersion !== undefined

const installedBehindTarget = (
  targetVersion: string | undefined,
  result: { readonly installedVersion: string }
): boolean => targetVersion !== undefined && isNewerVersion(targetVersion, result.installedVersion)

const errorMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
