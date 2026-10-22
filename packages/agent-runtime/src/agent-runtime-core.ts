import { isRecord } from "@codevisor/api"
import { Effect } from "effect"

import type { AgentRuntimeConfig } from "./agent-runtime-types.js"
import {
  locateExecutableOnPath,
  locateHarnessBinary as locateDefinitionBinary
} from "./executable-locator.js"
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

const announcedModeId = (
  event: RuntimeEvent,
  payload: Record<string, unknown>
): string | undefined => {
  if (event.kind === "session.updated" && typeof payload.modeId === "string") return payload.modeId
  if (
    event.kind === "session.output" &&
    payload.sessionUpdate === "current_mode_update" &&
    typeof payload.currentModeId === "string"
  )
    return payload.currentModeId
  return undefined
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
  const locateHarnessBinary = (definition: HarnessDefinition): string | undefined =>
    locateDefinitionBinary(definition, environment)
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
    if (isRecord(event.payload)) {
      const payload = event.payload
      if (event.kind === "session.updated" && Array.isArray(payload.configOptions)) {
        session.metadata = {
          ...session.metadata,
          configOptions: payload.configOptions as AgentSessionMetadata["configOptions"]
        }
      }
      const modeId = announcedModeId(event, payload)
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
    const described = withSteeringSupport(metadata, handle)
    sessions.set(sessionId, {
      chain: Promise.resolve(),
      cwd,
      eventSource,
      handle,
      harnessId,
      ...(account === undefined ? {} : { harnessAccountId: account.id }),
      metadata: described,
      phases: makeMessagePhases(),
      sink
    })
    return described
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

export const withSteeringSupport = (
  metadata: AgentSessionMetadata,
  handle: AgentSessionHandle
): AgentSessionMetadata => ({ ...metadata, supportsSteering: handle.steer !== undefined })
