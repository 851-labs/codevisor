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

/// Update-check bookkeeping shared by detection and the operations that
/// verify their outcome against it.
export interface HarnessCheckState {
  /// Last persisted state per harness, hydrated from the db on first use so
  /// clients see last-known knowledge before the first live check.
  states: Map<string, HarnessUpdateInfo> | undefined
  lastCheckAt: number
  inFlight: Promise<ReadonlyArray<HarnessUpdateCheckOutcome>> | undefined
}

/// Resolved settings, event fanout, persisted-state cache, live operation
/// registry, and the login-shell env cache every lifecycle module shares.
export const makeHarnessLifecycleCore = (config: HarnessLifecycleManagerConfig) => {
  const listeners = new Set<(event: HarnessLifecycleEvent) => void>()
  const fetchImpl = config.fetchImpl ?? (fetch as FetchLike)
  const now = config.now ?? (() => Date.now())
  const platform = config.platform ?? process.platform
  const arch = config.arch ?? process.arch
  const checkCacheMs = config.checkCacheMs ?? 5 * 60_000
  const checkIntervalMs = config.checkIntervalMs ?? 6 * 60 * 60_000
  const updateVerificationTimeoutMs = config.updateVerificationTimeoutMs ?? 2 * 60_000
  const updateVerificationPollIntervalMs = config.updateVerificationPollIntervalMs ?? 500
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
    } catch {
      // A fresh database simply starts empty.
    }
    checkState.states = loaded
    return loaded
  }

  /// Live operation (installing/updating) or terminal failure per harness.
  /// Success clears the entry (idle). In-memory on purpose: an interrupted
  /// operation dies with the process and readiness re-probes the truth.
  const operations = new Map<string, HarnessLifecycleState>()

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

  return {
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
    spawnShell,
    updateVerificationPollIntervalMs,
    updateVerificationTimeoutMs
  }
}

export type HarnessLifecycleCore = ReturnType<typeof makeHarnessLifecycleCore>
