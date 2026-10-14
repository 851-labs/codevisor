import type { HarnessDefinition } from "@codevisor/agent-runtime"
import type { HarnessLifecycleState, HarnessUpdateInfo } from "@codevisor/api"
import type { FetchLike } from "@codevisor/updater"

import {
  defaultReadBundleShortVersion,
  defaultSpawnShell,
  run
} from "./harness-lifecycle-support.js"
import type {
  HarnessLifecycleEvent,
  HarnessLifecycleManagerConfig,
  HarnessUpdateCheckOutcome
} from "./harness-lifecycle-types.js"

export interface HarnessCheckState {
  states: Map<string, HarnessUpdateInfo> | undefined
  lastCheckAt: number
  inFlight: Promise<ReadonlyArray<HarnessUpdateCheckOutcome>> | undefined
}

export const makeHarnessLifecycleCore = (config: HarnessLifecycleManagerConfig) => {
  const listeners = new Set<(event: HarnessLifecycleEvent) => void>()
  const fetchImpl = config.fetchImpl ?? (fetch as FetchLike)
  const now = config.now ?? (() => Date.now())
  const platform = config.platform ?? process.platform
  const arch = config.arch ?? process.arch
  const checkCacheMs = config.checkCacheMs ?? 5 * 60_000
  const checkIntervalMs = config.checkIntervalMs ?? 6 * 60 * 60_000
  const readBundleShortVersion = config.readBundleShortVersion ?? defaultReadBundleShortVersion
  const spawnShell = config.spawnShell ?? defaultSpawnShell
  const operationTimeoutMs = config.operationTimeoutMs ?? 10 * 60_000

  const checkState: HarnessCheckState = { inFlight: undefined, lastCheckAt: 0, states: undefined }

  const emit = (event: HarnessLifecycleEvent): void => {
    for (const listener of listeners) listener(event)
  }

  const loadStates = async (): Promise<Map<string, HarnessUpdateInfo>> => {
    if (checkState.states !== undefined) return checkState.states
    const loaded = new Map<string, HarnessUpdateInfo>()
    try {
      for (const record of await run(config.db.listHarnessUpdateStates)) {
        loaded.set(record.harnessId, record.info)
      }
    } catch {}
    checkState.states = loaded
    return loaded
  }

  const operations = new Map<string, HarnessLifecycleState>()
  const busyCounts = new Map<string, number>()
  const uninstallRequests = new Set<string>()
  const gateListeners = new Set<(harnessId: string) => void>()
  const startingOperations = new Set<string>()
  const settingUp = new Set<string>()

  const setOperation = (harnessId: string, state: HarnessLifecycleState | undefined): void => {
    if (state === undefined) operations.delete(harnessId)
    else operations.set(harnessId, state)
    const updateInfo = checkState.states?.get(harnessId)
    emit({
      kind: "harness.lifecycle.updated",
      payload: {
        harnessId,
        lifecycle: state ?? { phase: "idle" },
        ...(updateInfo === undefined ? {} : { updateInfo })
      },
      subjectId: harnessId
    })
  }

  const definitionOrThrow = (harnessId: string): HarnessDefinition => {
    const definition = config.agents.catalog.find((candidate) => candidate.id === harnessId)
    if (definition === undefined) throw new Error(`Unknown harness: ${harnessId}`)
    return definition
  }

  const resolveEnvUncached = config.resolveEnv ?? (() => Promise.resolve(process.env))
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

  const finishSetup = async (harnessId: string, onPending?: () => void): Promise<void> => {
    const setup = config.harnessSetup?.[harnessId]
    if (setup === undefined) return
    settingUp.add(harnessId)
    try {
      const pending = await setup(await resolveEnv())
      if (pending === undefined) return
      onPending?.()
      await pending.finish()
    } finally {
      settingUp.delete(harnessId)
      for (const listener of gateListeners) listener(harnessId)
    }
  }

  return {
    busyCounts,
    finishSetup,
    settingUp,
    uninstallRequests,
    gateListeners,
    startingOperations,
    arch,
    checkCacheMs,
    checkIntervalMs,
    checkState,
    config,
    definitionOrThrow,
    emit,
    fetchImpl,
    invalidateEnvCache,
    listeners,
    loadStates,
    now,
    operationTimeoutMs,
    operations,
    platform,
    readBundleShortVersion,
    resolveEnv,
    setOperation,
    spawnShell
  }
}

export type HarnessLifecycleCore = ReturnType<typeof makeHarnessLifecycleCore>
