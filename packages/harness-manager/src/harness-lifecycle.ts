import type { Harness } from "@codevisor/api"

import { makeBundledAppOperations } from "./harness-lifecycle-bundled-app.js"
import { makeHarnessLifecycleCore } from "./harness-lifecycle-core.js"
import { makeHarnessUpdateDetection, withMajorNotes } from "./harness-lifecycle-detection.js"
import { makeHarnessOperationRunner } from "./harness-lifecycle-execution.js"
import type {
  HarnessLifecycleManager,
  HarnessLifecycleManagerConfig
} from "./harness-lifecycle-types.js"
import { makeHarnessUninstall } from "./harness-lifecycle-uninstall.js"
import { makeHarnessUpdateGate } from "./harness-lifecycle-updates.js"

export type {
  HarnessLifecycleEvent,
  HarnessLifecycleManager,
  HarnessLifecycleManagerConfig,
  HarnessUpdateCheckOutcome,
  LifecycleProcess,
  PendingHarnessSetup
} from "./harness-lifecycle-types.js"

export const makeHarnessLifecycleManager = (
  config: HarnessLifecycleManagerConfig
): HarnessLifecycleManager => {
  const core = makeHarnessLifecycleCore(config)
  const detection = makeHarnessUpdateDetection(core)
  const runner = makeHarnessOperationRunner(core, detection)
  const gate = makeHarnessUpdateGate(core, runner)
  const bundledApp = makeBundledAppOperations(core, detection, runner)
  const { checkIntervalMs, listeners, loadStates, operations } = core

  const decorateHarnesses = async (
    harnesses: ReadonlyArray<Harness>
  ): Promise<ReadonlyArray<Harness>> => {
    const current = await loadStates()
    return Promise.all(
      harnesses.map(async (harness) => {
        const info = current.get(harness.id)
        const lifecycle = operations.get(harness.id)
        const definition =
          harness.readiness.state === "ready"
            ? undefined
            : config.agents.catalog.find((candidate) => candidate.id === harness.id)
        const methods =
          definition === undefined
            ? []
            : await runner.resolveInstallMethods(definition).catch(() => [])
        return {
          ...harness,
          ...(info === undefined
            ? {}
            : {
                updateInfo: withMajorNotes(
                  config.agents.catalog.find((candidate) => candidate.id === harness.id),
                  info
                )
              }),
          ...(lifecycle === undefined ? {} : { lifecycle }),
          ...(methods.length === 0 ? {} : { installMethods: methods })
        }
      })
    )
  }

  const finishPendingSetup = async (): Promise<void> => {
    await Promise.all(
      Object.keys(config.harnessSetup ?? {}).map(async (harnessId) => {
        const before = operations.get(harnessId)
        let shown = false
        try {
          await core.finishSetup(harnessId, () => {
            shown = true
            core.setOperation(harnessId, {
              phase: "updating",
              startedAt: new Date(core.now()).toISOString()
            })
          })
          if (shown) core.setOperation(harnessId, before)
        } catch (cause) {
          if (!shown) return
          core.setOperation(harnessId, {
            error: cause instanceof Error ? cause.message : String(cause),
            phase: "failed"
          })
        }
      })
    )
  }

  const startPeriodicChecks = (): (() => void) => {
    const initialDelay = 20_000 + Math.floor(Math.random() * 40_000)
    const initial = setTimeout(() => {
      void detection.checkForUpdates(true).catch(() => undefined)
    }, initialDelay)
    initial.unref()
    const interval = setInterval(() => {
      void detection.checkForUpdates(true).catch(() => undefined)
    }, checkIntervalMs)
    interval.unref()
    return () => {
      clearTimeout(initial)
      clearInterval(interval)
    }
  }

  return {
    ...gate,
    ...bundledApp,
    ...makeHarnessUninstall(core, runner),
    beginInstall: runner.beginInstall,
    checkForUpdates: async (force = false, harnessIds) => {
      if (force) {
        for (const [id, operation] of operations) {
          if (operation.phase !== "failed") continue
          if (harnessIds !== undefined && !harnessIds.includes(id)) continue
          core.setOperation(id, undefined)
        }
      }
      return detection.checkForUpdates(force, harnessIds)
    },
    decorateHarnesses,
    finishPendingSetup,
    startPeriodicChecks,
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}
