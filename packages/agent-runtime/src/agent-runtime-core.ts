import { Effect } from "effect"

import type { AgentRuntimeConfig } from "./agent-runtime-types.js"
import { locateExecutableOnPath } from "./executable-locator.js"
import { harnessCatalog } from "./harness-catalog.js"
import { makeMessagePhases, type MessagePhases } from "./message-phases.js"
import { SKILLS_UPDATE } from "./session-skills.js"
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
import { makeVersionProber } from "./version-probe.js"

export interface ManagedSession {
  readonly harnessId: string
  readonly harnessAccountId?: string
  readonly cwd: string
  readonly eventSource: object
  readonly handle: AgentSessionHandle
  metadata: AgentSessionMetadata
  sink: RuntimeEventSink
  chain: Promise<void>
  readonly phases: MessagePhases
}

export interface AgentRuntimeState {
  currentEnv: NodeJS.ProcessEnv
  envRefresh: Promise<void> | undefined
}

export const makeAgentRuntimeCore = (config: AgentRuntimeConfig) => {
  const state: AgentRuntimeState = {
    currentEnv: config.env ?? process.env,
    envRefresh: undefined
  }
  const locateExecutable = config.locateExecutable ?? locateExecutableOnPath
  const executableExists =
    config.executableExists ??
    ((name, environment) => locateExecutable(name, environment) !== undefined)
  const environment: ProviderEnvironment = {
    get env() {
      return state.currentEnv
    },
    envFor: (cwd) => config.resolveDirectoryEnv?.(cwd) ?? Promise.resolve(state.currentEnv),
    executableExists,
    locateExecutable
  }
  const versions = makeVersionProber(
    config.readVersionOutput === undefined ? {} : { readVersionOutput: config.readVersionOutput }
  )
  const locateHarnessBinary = (definition: HarnessDefinition): string | undefined => {
    for (const name of [...definition.detectBinaries, ...(definition.fallbackPaths ?? [])]) {
      const path = locateExecutable(name, state.currentEnv)
      if (path !== undefined) return path
    }
    return undefined
  }
  const locateReadyBinaries = (): ReadonlyArray<string> =>
    harnessCatalog.flatMap((definition) => {
      const path = locateHarnessBinary(definition)
      return path === undefined ? [] : [path]
    })
  const providers = new Map<ProviderId, AgentProvider>()
  for (const factory of config.providerFactories ?? []) {
    const provider = factory(environment)
    providers.set(provider.id, provider)
  }
  for (const provider of Object.values(config.providers ?? {})) {
    providers.set(provider.id, provider)
  }
  const sessions = new Map<string, ManagedSession>()
  const lifecycleTails = new Map<string, Promise<void>>()

  const withSessionLifecycle = async <A>(
    sessionId: string,
    operation: () => Promise<A>
  ): Promise<A> => {
    const previous = lifecycleTails.get(sessionId) ?? Promise.resolve()
    let release: (() => void) | undefined
    const gate = new Promise<void>((resolvePromise) => {
      release = resolvePromise
    })
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

  const dispatch = (eventSource: object, event: RuntimeEvent): Promise<void> => {
    const session = sessions.get(event.subjectId)
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
      if (
        event.kind === "session.output" &&
        payload.sessionUpdate === SKILLS_UPDATE &&
        Array.isArray(payload.skills) &&
        typeof payload.invocationPrefix === "string"
      ) {
        session.metadata = {
          ...session.metadata,
          skills: {
            invocationPrefix: payload.invocationPrefix,
            skills: payload.skills as NonNullable<AgentSessionMetadata["skills"]>["skills"]
          }
        }
      }
    }
    let next = session.chain
    for (const labeled of session.phases.label(event)) {
      next = next
        .then(() => session.sink(labeled))
        .then(
          () => undefined,
          /* v8 ignore next */
          () => undefined
        )
    }
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
      const definition = harnessCatalog.find((candidate) => candidate.id === harnessId)
      if (definition === undefined) {
        throw new Error(`Unknown harness: ${harnessId}`)
      }
      if (definition.disabledReason !== undefined) {
        throw new Error(`${definition.name} is unavailable: ${definition.disabledReason}`)
      }
      const provider = providers.get(definition.provider)
      /* v8 ignore next 3 */
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
      phases: makeMessagePhases(),
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
