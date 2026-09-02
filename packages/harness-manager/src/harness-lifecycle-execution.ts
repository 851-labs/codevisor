import { locateExecutableOnPath, type HarnessDefinition } from "@codevisor/agent-runtime"
import type { HarnessInstallMethod, HarnessLifecycleState } from "@codevisor/api"
import { applyAppBundleSwap, isNewerVersion } from "@codevisor/updater"
import type { HarnessLifecycleCore } from "./harness-lifecycle-core.js"
import type { HarnessUpdateDetection } from "./harness-lifecycle-detection.js"
import {
  installCommand,
  METHOD_PREFERENCE,
  methodPrerequisite,
  run
} from "./harness-lifecycle-support.js"

export interface RunOperationOptions {
  readonly harnessId: string
  readonly phase: "installing" | "updating"
  readonly command: string
  readonly extraEnv?: Readonly<Record<string, string>>
  readonly methodId?: string
  readonly targetVersion?: string
  readonly onSettled?: (success: boolean) => void
}

export interface StartBundleSwapOptions {
  readonly harnessId: string
  readonly bundle: string
  readonly appcastUrl: string
  readonly targetVersion?: string
  readonly onSettled?: (success: boolean) => void
  /// A dual-install app swap must not overwrite the primary CLI's update
  /// metadata with the bundled app's version.
  readonly recordsHarnessVersion?: boolean
}

/// Install/update execution: resolving runnable install methods, running a
/// vendor command in an attachable terminal until it settles, and the
/// verified app-bundle swap.
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
  const runOperation = async (
    options: RunOperationOptions
  ): Promise<{ readonly lifecycle: HarnessLifecycleState; readonly terminalId: string }> => {
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
        try {
          // Keep the operation visibly updating until the requested version
          // is actually observable. Some native updaters return after handing
          // replacement work to a descendant process.
          invalidateEnvCache()
          const installedVersion =
            options.phase === "updating" && options.targetVersion !== undefined
              ? await waitForInstalledTarget(options.harnessId, options.targetVersion)
              : undefined
          if (installedVersion === undefined) {
            await run(config.agents.refreshEnvironment).catch(() => undefined)
          }
          await checkForUpdatesFresh()
          if (installedVersion !== undefined) {
            await recordVerifiedInstalledVersion(options.harnessId, installedVersion)
          }
          setOperation(options.harnessId, undefined)
          options.onSettled?.(true)
        } catch (cause) {
          setOperation(options.harnessId, {
            error:
              `${cause instanceof Error ? cause.message : String(cause)}\n${outputTail.trim()}`.trim(),
            phase: "failed",
            terminalId: handle.terminalId,
            ...(options.methodId === undefined ? {} : { methodId: options.methodId }),
            ...(options.targetVersion === undefined ? {} : { targetVersion: options.targetVersion })
          })
          options.onSettled?.(false)
        }
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
    const lifecycle: HarnessLifecycleState = {
      phase: options.phase,
      startedAt: new Date(now()).toISOString(),
      terminalId: handle.terminalId,
      ...(options.methodId === undefined ? {} : { methodId: options.methodId }),
      ...(options.targetVersion === undefined ? {} : { targetVersion: options.targetVersion })
    }
    setOperation(options.harnessId, lifecycle)
    return { lifecycle, terminalId: handle.terminalId }
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

  /// Fires the verified bundle swap as a background operation on the
  /// harness's lifecycle state. Shared by the app-bundle-origin update path
  /// and the dual-install "update the app too" flow.
  const startBundleSwap = (options: StartBundleSwapOptions): HarnessLifecycleState => {
    const {
      appcastUrl,
      bundle,
      harnessId,
      onSettled,
      recordsHarnessVersion = true,
      targetVersion
    } = options
    const runningPhase = operations.get(harnessId)?.phase
    if (runningPhase === "installing" || runningPhase === "updating") {
      throw new Error(`An operation is already running for ${harnessId}`)
    }
    const applySwap = config.applyBundleSwap ?? applyAppBundleSwap
    const lifecycle: HarnessLifecycleState = {
      phase: "updating",
      startedAt: new Date(now()).toISOString(),
      ...(targetVersion === undefined ? {} : { targetVersion })
    }
    setOperation(harnessId, lifecycle)
    void (async () => {
      try {
        const response = await fetchImpl(appcastUrl, {
          signal: AbortSignal.timeout(30_000)
        })
        if (!response.ok) throw new Error(`Update feed unavailable (HTTP ${response.status})`)
        const result = await applySwap({ appcastXml: await response.text(), bundlePath: bundle })
        if (targetVersion !== undefined && isNewerVersion(targetVersion, result.installedVersion)) {
          throw new Error(
            `Bundle swap installed ${result.installedVersion}; expected ${targetVersion}`
          )
        }
        await run(config.agents.refreshEnvironment).catch(() => undefined)
        await checkForUpdatesFresh()
        if (recordsHarnessVersion) {
          await recordVerifiedInstalledVersion(harnessId, result.installedVersion)
        }
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
    return lifecycle
  }

  return { beginInstall, resolveInstallMethods, runOperation, startBundleSwap }
}

export type HarnessOperationRunner = ReturnType<typeof makeHarnessOperationRunner>
