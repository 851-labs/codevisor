import type { Harness } from "@codevisor/api"
import { makeBundledAppOperations } from "./harness-lifecycle-bundled-app.js"
import { makeHarnessLifecycleCore } from "./harness-lifecycle-core.js"
import { makeHarnessUpdateDetection } from "./harness-lifecycle-detection.js"
import { makeHarnessOperationRunner } from "./harness-lifecycle-execution.js"
import { makeHarnessUpdateGate } from "./harness-lifecycle-updates.js"
import type {
  HarnessLifecycleManager,
  HarnessLifecycleManagerConfig
} from "./harness-lifecycle-types.js"

export { appBundlePath } from "./harness-lifecycle-support.js"
export type {
  HarnessLifecycleEvent,
  HarnessLifecycleManager,
  HarnessLifecycleManagerConfig,
  HarnessUpdateCheckOutcome,
  LifecycleProcess
} from "./harness-lifecycle-types.js"

export const makeHarnessLifecycleManager = (
  config: HarnessLifecycleManagerConfig
): HarnessLifecycleManager => {
  const core = makeHarnessLifecycleCore(config)
  const detection = makeHarnessUpdateDetection(core)
  const runner = makeHarnessOperationRunner(core, detection)
  const gate = makeHarnessUpdateGate(core, runner)
  const bundledApp = makeBundledAppOperations(core, detection, runner)
  const { checkIntervalMs, definitionOrThrow, listeners, loadStates, operations } = core

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
          definition === undefined
            ? []
            : await runner.resolveInstallMethods(definition).catch(() => [])
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
    beginInstall: runner.beginInstall,
    checkForUpdates: detection.checkForUpdates,
    decorateHarnesses,
    installMethods: async (harnessId) => runner.resolveInstallMethods(definitionOrThrow(harnessId)),
    startPeriodicChecks,
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}
