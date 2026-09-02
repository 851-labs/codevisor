import type { HarnessInstallMethodSpec } from "@codevisor/agent-runtime"
import type { HarnessLifecycleState } from "@codevisor/api"
import type { HarnessPendingUpdateRecord } from "@codevisor/db"
import { detectBrewPackage, detectInstallOrigin } from "@codevisor/updater"
import type { HarnessLifecycleCore } from "./harness-lifecycle-core.js"
import { matchSource } from "./harness-lifecycle-detection.js"
import type { HarnessOperationRunner } from "./harness-lifecycle-execution.js"
import { appBundlePath, run, sparkleFeedUrl, upgradeCommand } from "./harness-lifecycle-support.js"
import type { HarnessLifecycleManager } from "./harness-lifecycle-types.js"

export type HarnessUpdateGate = Pick<
  HarnessLifecycleManager,
  | "beginUpdate"
  | "cancelPendingUpdate"
  | "forcePendingUpdate"
  | "isGated"
  | "notifyTurnEnded"
  | "notifyTurnStarted"
  | "onGateReleased"
  | "reconcileOnStartup"
>

type BeginUpdateResult = Awaited<ReturnType<HarnessLifecycleManager["beginUpdate"]>>

/// The update path plus its when-idle gate: origin-matched execution,
/// durable pending updates armed while chats are mid-turn, and the
/// startup reconciliation that never resurrects a gate.
export const makeHarnessUpdateGate = (
  core: HarnessLifecycleCore,
  runner: HarnessOperationRunner
): HarnessUpdateGate => {
  const {
    arch,
    config,
    definitionOrThrow,
    loadStates,
    now,
    operationTimeoutMs,
    platform,
    setOperation
  } = core
  const { runOperation, startBundleSwap } = runner

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

  const executeUpdateNow = async (
    harnessId: string,
    onSettled?: (success: boolean) => void
  ): Promise<BeginUpdateResult> => {
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
        const { lifecycle, terminalId } = await runOperation({
          command: [path, ...source.apply.args].join(" "),
          harnessId,
          phase: "updating",
          ...(source.apply.env === undefined ? {} : { extraEnv: source.apply.env }),
          ...(targetVersion === undefined ? {} : { targetVersion }),
          ...(onSettled === undefined ? {} : { onSettled })
        })
        return { lifecycle, queued: false, terminalId }
      }
      case "reinstall": {
        const detectedBrew =
          origin === "brew"
            ? detectBrewPackage(
                path,
                config.realpath === undefined ? {} : { realpath: config.realpath }
              )
            : undefined
        const spec: HarnessInstallMethodSpec | undefined =
          detectedBrew === undefined
            ? (definition.installMethods ?? []).find(
                (candidate) =>
                  candidate.kind ===
                  (origin === "brew" ? "brew" : origin === "curl" ? "curl" : "npm")
              )
            : { cask: detectedBrew.cask, formula: detectedBrew.formula, kind: "brew" }
        if (spec === undefined)
          throw new Error(`${harnessId} has no reinstall method for ${origin}`)
        const { lifecycle, terminalId } = await runOperation({
          command: upgradeCommand(spec),
          harnessId,
          methodId: spec.kind,
          phase: "updating",
          ...(targetVersion === undefined ? {} : { targetVersion }),
          ...(onSettled === undefined ? {} : { onSettled })
        })
        return { lifecycle, queued: false, terminalId }
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
        const lifecycle = startBundleSwap({
          appcastUrl: sparkleFeedUrl(arch, source.check),
          bundle,
          harnessId,
          ...(targetVersion === undefined ? {} : { targetVersion }),
          ...(onSettled === undefined ? {} : { onSettled })
        })
        return { lifecycle, queued: false }
      }
    }
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

  const beginUpdate: HarnessLifecycleManager["beginUpdate"] = async (harnessId) => {
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
      const lifecycle: HarnessLifecycleState = {
        phase: "pendingUpdate",
        startedAt: record.requestedAt,
        ...(targetVersion === undefined ? {} : { targetVersion })
      }
      setOperation(harnessId, lifecycle)
      return { lifecycle, queued: true }
    }
    return executeUpdateNow(harnessId)
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
    beginUpdate,
    cancelPendingUpdate,
    forcePendingUpdate,
    isGated,
    notifyTurnEnded,
    notifyTurnStarted,
    onGateReleased: (listener) => {
      gateListeners.add(listener)
      return () => gateListeners.delete(listener)
    },
    reconcileOnStartup
  }
}
