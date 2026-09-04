import type { EventEnvelope, Harness } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Context, Effect, Layer } from "effect"
import { makeAgentRuntimeCore, withoutBuiltinCollisions } from "./agent-runtime-core.js"
import { makeAgentSessionOperations } from "./agent-runtime-sessions.js"
import type { AgentRuntimeConfig, AgentRuntimeService } from "./agent-runtime-types.js"
import { harnessCatalog } from "./harness-catalog.js"
import { adapterPromise, runtimeError, type RuntimeEvent } from "./types.js"

export * from "./types.js"
export * from "./attachments.js"
export * from "./background-terminals.js"
export * from "./diff-stats.js"
export * from "./shell-env.js"
export * from "./agent-sessions.js"
export * from "./stdio-transport.js"
export * from "./model-selection.js"
export * from "./agent-runtime-types.js"
export { harnessCatalog } from "./harness-catalog.js"
export { locateExecutableOnPath } from "./executable-locator.js"
export { makeVersionProber, parseVersionOutput } from "./version-probe.js"
export type { VersionProber, VersionProberOptions } from "./version-probe.js"
export {
  clampFailureDetail,
  maxFailureDetailLength,
  summarizeProcessFailure
} from "./process-failure.js"

export class AgentRuntime extends Context.Service<AgentRuntime, AgentRuntimeService>()(
  "@codevisor/agent-runtime/AgentRuntime"
) {
  static readonly layer = (config: AgentRuntimeConfig = {}): Layer.Layer<AgentRuntime> =>
    Layer.succeed(AgentRuntime, AgentRuntime.of(makeAgentRuntime(config)))
}

export const makeAgentRuntime = (config: AgentRuntimeConfig = {}): AgentRuntimeService => {
  const core = makeAgentRuntimeCore(config)
  const {
    createSessionEmitter,
    definitionFor,
    locateHarnessBinary,
    locateReadyBinaries,
    manageSession,
    providers,
    sessions,
    state,
    versions,
    withSessionLifecycle
  } = core

  return {
    get catalog() {
      return state.catalog
    },
    setExtraHarnesses: (definitions) => {
      state.extraHarnesses = withoutBuiltinCollisions(definitions)
      state.catalog =
        state.extraHarnesses.length === 0
          ? harnessCatalog
          : [...harnessCatalog, ...state.extraHarnesses]
    },
    discoverHarnesses: Effect.sync(() =>
      state.catalog.map((definition) => {
        const provider = providers.get(definition.provider)
        let readiness: Harness["readiness"]
        if (definition.disabledReason !== undefined) {
          readiness = { detail: definition.disabledReason, state: "unavailable" }
          /* v8 ignore start -- every catalog provider id is registered; guards future ids. */
        } else if (provider === undefined) {
          readiness = { detail: "Provider not available", state: "unavailable" }
          /* v8 ignore stop */
        } else {
          readiness = provider.readiness(definition)
        }
        if (readiness.state === "ready") {
          const path = locateHarnessBinary(definition)
          if (path !== undefined) {
            // Versions come from the refreshEnvironment probe cache: the
            // server refreshes at boot and on every rescan, so discovery
            // stays synchronous and spawn-free.
            const version = versions.get(path)
            readiness = {
              ...readiness,
              path,
              ...(version === undefined ? {} : { version })
            }
          }
        }
        return {
          id: definition.id,
          name: definition.name,
          symbolName: definition.symbolName,
          source: state.extraHarnesses.includes(definition) ? "custom" : "registry",
          launchKind:
            definition.launch?.kind === "npx" ? ("npx" as const) : ("executable" as const),
          enabled: true,
          readiness,
          ...(definition.installHint === undefined ? {} : { installHint: definition.installHint })
        }
      })
    ),
    listAgentSessions: (harnessId, account) =>
      adapterPromise("listAgentSessions", async () => {
        const definition = state.catalog.find((candidate) => candidate.id === harnessId)
        if (definition === undefined) {
          throw new Error(`Unknown harness: ${harnessId}`)
        }
        // Deliberately no disabledReason check: a pulled integration's past
        // sessions still inform workspace suggestions.
        const provider = providers.get(definition.provider)
        /* v8 ignore next 3 -- every catalog provider id is registered above; guards future ids. */
        if (provider === undefined) {
          return []
        }
        const list = provider.listAgentSessions
        return list === undefined ? [] : await list(definition, account)
      }),
    readHarnessUsageLimits: (harnessId, cwd, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        if (provider.readUsageLimits === undefined) {
          return {
            detail: "This harness does not expose account usage limits.",
            fetchedAt: isoTimestamp(),
            harnessId,
            state: "unavailable" as const,
            windows: []
          }
        }
        return yield* provider.readUsageLimits(definition, cwd, account)
      }),
    refreshEnvironment: adapterPromise("refreshEnvironment", () => {
      const resolveEnv = config.resolveEnv
      if (resolveEnv === undefined) {
        // Still settle version probes so a rescan without an env resolver
        // (embedded runtimes, tests) reports complete readiness.
        return versions.probe(locateReadyBinaries(), state.currentEnv)
      }
      // Concurrent refreshes (Settings + onboarding both rescanning) share
      // one shell probe instead of stacking login-shell invocations.
      state.envRefresh ??= resolveEnv()
        .then((resolved) => {
          state.currentEnv = resolved
        })
        // Awaited (not fire-and-forget) so the rescan response that follows
        // a refresh carries binary versions, not a cache miss.
        .then(() => versions.probe(locateReadyBinaries(), state.currentEnv))
        .finally(() => {
          state.envRefresh = undefined
        })
      return state.envRefresh
    }),
    createAgentSession: (harnessId, cwd, sink, account, toolGateway) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        const events = createSessionEmitter()
        const created = yield* provider.createSession(
          definition,
          cwd,
          events.emit,
          account,
          toolGateway
        )
        manageSession(
          harnessId,
          created.metadata,
          cwd,
          created.handle,
          events.eventSource,
          sink,
          account
        )
        return created.metadata.sessionId
      }),
    inspectHarness: (harnessId, cwd, account, configSelections) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        const timeoutMs = config.harnessInspectionTimeoutMs ?? 15_000
        const created = yield* provider
          .createSession(
            definition,
            cwd,
            /* v8 ignore next -- inspection sessions are closed before they can emit. */
            () => Promise.resolve(),
            account,
            undefined,
            // Inspection's whole point is the option list: grant it most of
            // the outer timeout instead of the snappy interactive default.
            { modelListTimeoutMs: Math.max(3_000, timeoutMs - 3_000) }
          )
          .pipe(
            Effect.timeout(timeoutMs),
            Effect.mapError((cause) =>
              runtimeError(
                "inspectHarness",
                cause._tag === "TimeoutError"
                  ? new Error(`Harness inspection timed out after ${timeoutMs}ms`)
                  : cause
              )
            )
          )
        let configOptions = created.metadata.configOptions
        const selections = Object.entries(configSelections ?? {}).toSorted(([left], [right]) => {
          if (left === "model") return -1
          if (right === "model") return 1
          return left.localeCompare(right)
        })
        for (const [configId, value] of selections) {
          const option = configOptions.find((candidate) => candidate.id === configId)
          const selectableValues =
            option?.options.flatMap((entry) =>
              "value" in entry ? [entry.value] : entry.options.map((nested) => nested.value)
            ) ?? []
          if (!selectableValues.includes(value) || option?.currentValue === value) continue
          configOptions = yield* created.handle
            .setConfigOption(configId, value)
            .pipe(Effect.catchCause(() => Effect.succeed(configOptions)))
        }
        void Effect.runPromise(created.handle.close).catch(() => undefined)
        return { ...created.metadata, configOptions }
      }),
    loadedAgentSessionIds: () => [...sessions.keys()],
    loadAgentSession: (harnessId, agentSessionId, cwd, sink, account, toolGateway) =>
      adapterPromise("loadAgentSession", () =>
        withSessionLifecycle(agentSessionId, async () => {
          const existing = sessions.get(agentSessionId)
          if (
            existing !== undefined &&
            existing.harnessId === harnessId &&
            existing.cwd === cwd &&
            existing.harnessAccountId === account?.id
          ) {
            // Reconnects re-bind the sink (e.g. a restarted client re-loading
            // a live session) without tearing down the agent process.
            existing.sink = sink
            return existing.metadata
          }

          if (existing !== undefined) {
            // Finish delivering everything the old handle already emitted,
            // then unmanage it before closing. Closing a Claude query aborts
            // its SDK stream; any late shutdown event must be unable to land
            // in either the old sink or the replacement session.
            await existing.chain
            if (sessions.get(agentSessionId) === existing) {
              sessions.delete(agentSessionId)
            }
            await Effect.runPromise(existing.handle.close).catch(() => undefined)
          }

          const { definition, provider } = await Effect.runPromise(definitionFor(harnessId))
          const events = createSessionEmitter()
          const loaded = await Effect.runPromise(
            provider.loadSession(definition, agentSessionId, cwd, events.emit, account, toolGateway)
          )
          const metadata = loaded.metadata ?? { configOptions: [], sessionId: loaded.sessionId }
          return manageSession(
            harnessId,
            metadata,
            cwd,
            loaded.handle,
            events.eventSource,
            sink,
            account
          )
        })
      ),
    ...makeAgentSessionOperations(core)
  }
}

export const toEventEnvelope = (
  serverId: string,
  id: number,
  event: RuntimeEvent
): EventEnvelope => ({
  id,
  serverId,
  kind: event.kind,
  subjectId: event.subjectId,
  createdAt: isoTimestamp(),
  payload: event.payload
})
