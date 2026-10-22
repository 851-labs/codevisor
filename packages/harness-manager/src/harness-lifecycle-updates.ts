import { realpathSync } from "node:fs"

import type { HarnessDefinition, HarnessInstallMethodSpec } from "@codevisor/agent-runtime"
import type { HarnessLifecycleState } from "@codevisor/api"
import { detectBrewPackage, detectInstallOrigin } from "@codevisor/updater"

import type { HarnessLifecycleCore } from "./harness-lifecycle-core.js"
import { matchSource } from "./harness-lifecycle-detection.js"
import type { HarnessOperationRunner } from "./harness-lifecycle-execution.js"
import {
  appBundlePath,
  installCommand,
  run,
  sparkleFeedUrl,
  upgradeCommand
} from "./harness-lifecycle-support.js"
import type { HarnessLifecycleManager } from "./harness-lifecycle-types.js"

export type HarnessUpdates = Pick<
  HarnessLifecycleManager,
  | "applyUpdate"
  | "cancelUpdate"
  | "isGated"
  | "notifyTurnEnded"
  | "notifyTurnStarted"
  | "onGateReleased"
  | "prepareUpdate"
>

export const makeHarnessUpdates = (
  core: HarnessLifecycleCore,
  runner: HarnessOperationRunner
): HarnessUpdates => {
  const { arch, config, definitionOrThrow, loadStates, now, platform, setOperation } = core
  const { runOperation, startBundleSwap } = runner

  const gateListeners = core.gateListeners
  const prepared = new Set<string>()
  const busyCounts = core.busyCounts

  const replacedInstall = (
    definition: HarnessDefinition,
    origin: string,
    path: string,
    brewFormula: string | undefined
  ): { readonly command: string; readonly methodId: string } | undefined => {
    const replaces = definition.update?.replaces
    const method = (kind: HarnessInstallMethodSpec["kind"]) =>
      (definition.installMethods ?? []).find((candidate) => candidate.kind === kind)
    const brew = method("brew")
    if (
      brew !== undefined &&
      brewFormula !== undefined &&
      replaces?.brew?.split("/").at(-1) === brewFormula
    )
      return {
        command: `brew uninstall ${brewFormula} && ${installCommand(brew)}`,
        methodId: "brew"
      }
    const npm = method("npm")
    const resolved = (() => {
      try {
        return (config.realpath ?? realpathSync)(path)
      } catch {
        return path
      }
    })()
    if (
      npm !== undefined &&
      origin === "npm" &&
      replaces?.npm !== undefined &&
      resolved.includes(`/node_modules/${replaces.npm}/`)
    )
      return {
        command: `npm uninstall -g ${replaces.npm} && ${installCommand(npm)}`,
        methodId: "npm"
      }
    return undefined
  }

  const executeUpdateNow = async (
    harnessId: string,
    onSettled: (success: boolean) => void
  ): Promise<void> => {
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
        await runOperation({
          command: [path, ...source.apply.args].join(" "),
          harnessId,
          phase: "updating",
          ...(source.apply.env === undefined ? {} : { extraEnv: source.apply.env }),
          ...(targetVersion === undefined ? {} : { targetVersion }),
          onSettled
        })
        return
      }
      case "reinstall": {
        let detectedBrew: ReturnType<typeof detectBrewPackage>
        if (origin === "brew") {
          detectedBrew = detectBrewPackage(
            path,
            config.realpath === undefined ? {} : { realpath: config.realpath }
          )
        }
        const replacement = replacedInstall(definition, origin, path, detectedBrew?.formula)
        if (replacement !== undefined) {
          await runOperation({
            command: replacement.command,
            harnessId,
            methodId: replacement.methodId,
            phase: "updating",
            ...(targetVersion === undefined ? {} : { targetVersion }),
            onSettled
          })
          return
        }
        const spec: HarnessInstallMethodSpec | undefined =
          detectedBrew === undefined
            ? (definition.installMethods ?? []).find(
                (candidate) =>
                  candidate.kind ===
                  (origin === "brew" || origin === "curl" || origin === "uv" ? origin : "npm")
              )
            : { cask: detectedBrew.cask, formula: detectedBrew.formula, kind: "brew" }
        if (spec === undefined)
          throw new Error(`${harnessId} has no reinstall method for ${origin}`)
        await runOperation({
          command: upgradeCommand(spec),
          harnessId,
          methodId: spec.kind,
          phase: "updating",
          ...(targetVersion === undefined ? {} : { targetVersion }),
          onSettled
        })
        return
      }
      default: {
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
          appcastUrl: sparkleFeedUrl(arch, source.check),
          bundle,
          harnessId,
          ...(targetVersion === undefined ? {} : { targetVersion }),
          onSettled
        })
      }
    }
  }

  const prepareUpdate: HarnessLifecycleManager["prepareUpdate"] = async (harnessId) => {
    definitionOrThrow(harnessId)
    if (core.uninstallRequests.has(harnessId)) throw new Error("Uninstall in progress")
    if (operationRunning(harnessId)) {
      throw new Error(`An operation is already running for ${harnessId}`)
    }

    const targetVersion = (await loadStates()).get(harnessId)?.latestVersion
    const lifecycle: HarnessLifecycleState = {
      phase: "updating",
      startedAt: new Date(now()).toISOString(),
      ...(targetVersion === undefined ? {} : { targetVersion })
    }
    prepared.add(harnessId)
    setOperation(harnessId, lifecycle)
    return lifecycle
  }

  const applyUpdate: HarnessLifecycleManager["applyUpdate"] = async (harnessId) => {
    const settled = Promise.withResolvers<boolean>()
    const targetVersion = core.operations.get(harnessId)?.targetVersion
    clearPrepared(harnessId)
    try {
      await executeUpdateNow(harnessId, settled.resolve)
    } catch (cause) {
      setOperation(harnessId, {
        error: cause instanceof Error ? cause.message : String(cause),
        phase: "failed",
        ...(targetVersion === undefined ? {} : { targetVersion })
      })
      return false
    }
    return settled.promise
  }

  const cancelUpdate = (harnessId: string): void => {
    if (!prepared.has(harnessId)) return

    clearPrepared(harnessId)
  }

  const clearPrepared = (harnessId: string): void => {
    prepared.delete(harnessId)
    setOperation(harnessId, undefined)
  }

  const operationRunning = (harnessId: string): boolean => {
    const phase = core.operations.get(harnessId)?.phase
    return phase !== undefined && phase !== "failed"
  }

  const notifyTurnStarted = (harnessId: string): void => {
    busyCounts.set(harnessId, (busyCounts.get(harnessId) ?? 0) + 1)
  }

  const notifyTurnEnded = (harnessId: string): void => {
    const next = Math.max(0, (busyCounts.get(harnessId) ?? 0) - 1)
    if (next === 0) busyCounts.delete(harnessId)
    else busyCounts.set(harnessId, next)
  }

  const isGated = (harnessId: string): boolean =>
    core.uninstallRequests.has(harnessId) || core.settingUp.has(harnessId)

  return {
    applyUpdate,
    cancelUpdate,
    isGated,
    notifyTurnEnded,
    notifyTurnStarted,
    onGateReleased: (listener) => {
      gateListeners.add(listener)
      return () => gateListeners.delete(listener)
    },
    prepareUpdate
  }
}
