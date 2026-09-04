import { Effect } from "effect"
import { harnessCatalog } from "./harness-catalog.js"
import { locateExecutableOnPath } from "./executable-locator.js"
import { makeVersionProber } from "./version-probe.js"
import type { AgentRuntimeConfig, ProviderFactoryContext } from "./agent-runtime-types.js"
import {
  runtimeEffect,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type AgentSessionMetadata,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type ProviderId,
  type RuntimeEmit,
  type RuntimeEvent,
  type RuntimeEventSink
} from "./types.js"

export interface ManagedSession {
  readonly harnessId: string
  readonly harnessAccountId?: string
  readonly cwd: string
  readonly eventSource: object
  readonly handle: AgentSessionHandle
  metadata: AgentSessionMetadata
  sink: RuntimeEventSink
  chain: Promise<void>
}

/// Runtime state that swaps live after construction: the effective catalog
/// (setExtraHarnesses), the resolved environment (refreshEnvironment), and
/// the shared in-flight refresh.
export interface AgentRuntimeState {
  extraHarnesses: ReadonlyArray<HarnessDefinition>
  catalog: ReadonlyArray<HarnessDefinition>
  currentEnv: NodeJS.ProcessEnv
  envRefresh: Promise<void> | undefined
}

/// A colliding extra id is dropped so a custom entry can never shadow (or
/// break) a builtin harness.
export const withoutBuiltinCollisions = (
  definitions: ReadonlyArray<HarnessDefinition>
): ReadonlyArray<HarnessDefinition> =>
  definitions.filter((extra) => !harnessCatalog.some((builtin) => builtin.id === extra.id))

/// The registries and per-session plumbing every runtime operation shares:
/// providers, managed sessions, the lifecycle serializer, and the event
/// dispatcher that keeps a session's sink observing events in order.
export const makeAgentRuntimeCore = (config: AgentRuntimeConfig) => {
  // Effective catalog: builtins first, then injected user-defined entries.
  // Both are mutable state: setExtraHarnesses swaps them live (the
  // custom-harness PUT route), so every internal consumer reads them lazily
  // rather than capturing.
  const extraHarnesses = withoutBuiltinCollisions(config.extraHarnesses ?? [])
  const state: AgentRuntimeState = {
    catalog: extraHarnesses.length === 0 ? harnessCatalog : [...harnessCatalog, ...extraHarnesses],
    currentEnv: config.env ?? process.env,
    envRefresh: undefined,
    extraHarnesses
  }
  const locateExecutable = config.locateExecutable ?? locateExecutableOnPath
  const executableExists =
    config.executableExists ??
    ((name, environment) => locateExecutable(name, environment) !== undefined)
  // A getter so every provider sees environment refreshes without re-wiring:
  // providers read `environment.env` lazily at readiness/launch time.
  const environment: ProviderEnvironment = {
    get env() {
      return state.currentEnv
    },
    executableExists,
    locateExecutable
  }
  const versions = makeVersionProber(
    config.readVersionOutput === undefined ? {} : { readVersionOutput: config.readVersionOutput }
  )
  /// First detect binary (or absolute fallback path) present in the current
  /// environment — the same candidates providers scan for readiness.
  const locateHarnessBinary = (definition: HarnessDefinition): string | undefined => {
    for (const name of [...definition.detectBinaries, ...(definition.fallbackPaths ?? [])]) {
      const path = locateExecutable(name, state.currentEnv)
      if (path !== undefined) return path
    }
    return undefined
  }
  const locateReadyBinaries = (): ReadonlyArray<string> =>
    state.catalog.flatMap((definition) => {
      const path = locateHarnessBinary(definition)
      return path === undefined ? [] : [path]
    })
  const providers = new Map<ProviderId, AgentProvider>()
  const factoryContext: ProviderFactoryContext =
    config.backgroundTerminals === undefined
      ? {}
      : { backgroundTerminals: config.backgroundTerminals }
  for (const factory of config.providerFactories ?? []) {
    const provider = factory(environment, factoryContext)
    providers.set(provider.id, provider)
  }
  for (const provider of Object.values(config.providers ?? {})) {
    providers.set(provider.id, provider)
  }
  const sessions = new Map<string, ManagedSession>()
  const lifecycleTails = new Map<string, Promise<void>>()

  /// Serializes load/cancel/close for one durable provider session. In
  /// particular, a new load cannot observe a handle while an earlier forced
  /// cancellation is still flushing and retiring it.
  const withSessionLifecycle = async <A>(
    sessionId: string,
    operation: () => Promise<A>
  ): Promise<A> => {
    const previous = lifecycleTails.get(sessionId) ?? Promise.resolve()
    let release: (() => void) | undefined
    const gate = new Promise<void>((resolvePromise) => {
      release = resolvePromise
    })
    // Every stored tail resolves through the gate released in `finally`, so
    // later operations can await it directly without unreachable catch paths.
    const tail = previous.then(() => gate)
    lifecycleTails.set(sessionId, tail)
    await previous
    try {
      return await operation()
    } finally {
      release?.()
      if (lifecycleTails.get(sessionId) === tail) {
        lifecycleTails.delete(sessionId)
      }
    }
  }

  /// All session output funnels through here. Events append to the owning
  /// session's serial promise chain so the sink observes them in arrival
  /// order — including events with no prompt in flight, which is how
  /// agent-initiated turns reach the server.
  const dispatch = (eventSource: object, event: RuntimeEvent): Promise<void> => {
    const session = sessions.get(event.subjectId)
    // Provider processes can finish shutting down after their replacement is
    // already live. Events are scoped to the handle that produced them so a
    // retired process can never mutate the replacement's durable session.
    if (session === undefined || session.eventSource !== eventSource) {
      return Promise.resolve()
    }
    if (typeof event.payload === "object" && event.payload !== null) {
      const payload = event.payload as Record<string, unknown>
      if (event.kind === "session.updated" && Array.isArray(payload.configOptions)) {
        session.metadata = {
          ...session.metadata,
          configOptions: payload.configOptions as AgentSessionMetadata["configOptions"]
        }
      }
      const modeId =
        event.kind === "session.updated" && typeof payload.modeId === "string"
          ? payload.modeId
          : event.kind === "session.output" &&
              payload.sessionUpdate === "current_mode_update" &&
              typeof payload.currentModeId === "string"
            ? payload.currentModeId
            : undefined
      if (modeId !== undefined && session.metadata.modes !== undefined) {
        session.metadata = {
          ...session.metadata,
          modes: { ...session.metadata.modes, currentModeId: modeId }
        }
      }
    }
    const next = session.chain
      .then(() => session.sink(event))
      .then(
        () => undefined,
        /* v8 ignore next -- defensive: a sink failure must not wedge the chain. */
        () => undefined
      )
    session.chain = next
    return next
  }

  const createSessionEmitter = (): { readonly eventSource: object; readonly emit: RuntimeEmit } => {
    const eventSource = {}
    return {
      eventSource,
      emit: (event) => dispatch(eventSource, event)
    }
  }

  const definitionFor = (
    harnessId: string
  ): Effect.Effect<
    { readonly definition: HarnessDefinition; readonly provider: AgentProvider },
    AgentRuntimeError
  > =>
    runtimeEffect("resolveHarness", () => {
      const definition = state.catalog.find((candidate) => candidate.id === harnessId)
      if (definition === undefined) {
        throw new Error(`Unknown harness: ${harnessId}`)
      }
      if (definition.disabledReason !== undefined) {
        throw new Error(`${definition.name} is unavailable: ${definition.disabledReason}`)
      }
      const provider = providers.get(definition.provider)
      /* v8 ignore next 3 -- every catalog provider id is registered above; guards future ids. */
      if (provider === undefined) {
        throw new Error(`No provider registered for harness: ${harnessId}`)
      }
      return { definition, provider }
    })

  const manageSession = (
    harnessId: string,
    metadata: AgentSessionMetadata,
    cwd: string,
    handle: AgentSessionHandle,
    eventSource: object,
    sink: RuntimeEventSink,
    account?: HarnessAccountContext
  ): AgentSessionMetadata => {
    const sessionId = metadata.sessionId
    const previous = sessions.get(sessionId)
    if (previous !== undefined && previous.handle !== handle) {
      void Effect.runPromise(previous.handle.close).catch(() => undefined)
    }
    sessions.set(sessionId, {
      chain: Promise.resolve(),
      cwd,
      eventSource,
      handle,
      harnessId,
      ...(account === undefined ? {} : { harnessAccountId: account.id }),
      metadata,
      sink
    })
    return metadata
  }

  const sessionFor = (sessionId: string): Effect.Effect<ManagedSession, AgentRuntimeError> =>
    runtimeEffect("sessionFor", () => {
      const session = sessions.get(sessionId)
      if (session === undefined) {
        throw new Error(`Agent session is not loaded: ${sessionId}`)
      }
      return session
    })

  return {
    config,
    createSessionEmitter,
    definitionFor,
    locateHarnessBinary,
    locateReadyBinaries,
    manageSession,
    providers,
    sessionFor,
    sessions,
    state,
    versions,
    withSessionLifecycle
  }
}

export type AgentRuntimeCore = ReturnType<typeof makeAgentRuntimeCore>
