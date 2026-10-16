import type { Harness } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Cause, Effect } from "effect"

import { makeAgentRuntimeCore } from "./agent-runtime-core.js"
import { makeAgentSessionOperations } from "./agent-runtime-sessions.js"
import type { AgentRuntimeConfig, AgentRuntimeService } from "./agent-runtime-types.js"
import { harnessCatalog } from "./harness-catalog.js"
import { placeConfigValue } from "./model-selection.js"
import { adapterPromise, runtimeError } from "./types.js"

export * from "./types.js"
export * from "./attachments.js"
export * from "./diff-stats.js"
export * from "./shell-env.js"
export * from "./agent-sessions.js"
export * from "./stdio-transport.js"
export * from "./model-selection.js"
export * from "./session-skills.js"
export * from "./agent-runtime-types.js"
export { harnessCatalog, OPENCODE_INSTALL_PATH } from "./harness-catalog.js"
export { locateExecutableOnPath, locateHarnessBinary } from "./executable-locator.js"
export { binaryIdentity, makeVersionProber } from "./version-probe.js"
export type { VersionProbeOptions, VersionProber, VersionProberOptions } from "./version-probe.js"
export { clampFailureDetail, summarizeProcessFailure } from "./process-failure.js"

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
    catalog: harnessCatalog,
    discoverHarnesses: Effect.sync(() =>
      harnessCatalog.map((definition) => {
        const provider = providers.get(definition.provider)
        let readiness: Harness["readiness"]
        if (definition.disabledReason !== undefined) {
          readiness = { detail: definition.disabledReason, state: "unavailable" }
          /* v8 ignore start */
        } else if (provider === undefined) {
          readiness = { detail: "Provider not available", state: "unavailable" }
          /* v8 ignore stop */
        } else {
          readiness = provider.readiness(definition)
        }
        if (readiness.state === "ready") {
          const path = locateHarnessBinary(definition)
          if (path !== undefined) {
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
          source: "registry",
          launchKind:
            definition.launch?.kind === "npx" ? ("npx" as const) : ("executable" as const),
          enabled: true,
          readiness,
          ...(definition.installHint === undefined ? {} : { installHint: definition.installHint })
        }
      })
    ),
    listAgentSessions: (harnessId, account, options) =>
      adapterPromise("listAgentSessions", async () => {
        const definition = harnessCatalog.find((candidate) => candidate.id === harnessId)
        if (definition === undefined) {
          throw new Error(`Unknown harness: ${harnessId}`)
        }
        const provider = providers.get(definition.provider)
        /* v8 ignore next 3 */
        if (provider === undefined) {
          return []
        }
        const list = provider.listAgentSessions
        return list === undefined ? [] : await list(definition, account, options)
      }),
    reconcileConfigValue: (harnessId, option, value) => {
      const definition = harnessCatalog.find((candidate) => candidate.id === harnessId)
      const provider = definition === undefined ? undefined : providers.get(definition.provider)
      return provider?.reconcileConfigValue?.(option, value)
    },
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
        return versions.probe(locateReadyBinaries(), state.currentEnv)
      }
      state.envRefresh ??= resolveEnv()
        .then((resolved) => {
          state.currentEnv = resolved
        })
        .then(() => versions.probe(locateReadyBinaries(), state.currentEnv))
        .finally(() => {
          state.envRefresh = undefined
        })
      return state.envRefresh
    }),
    refreshHarnessVersions: (harnessIds) =>
      adapterPromise("refreshHarnessVersions", async () => {
        await Promise.allSettled([state.envRefresh])
        const ids = new Set(harnessIds)
        const paths = harnessCatalog.flatMap((definition) => {
          const path = ids.has(definition.id) ? locateHarnessBinary(definition) : undefined
          return path === undefined ? [] : [path]
        })
        await versions.probe(paths, state.currentEnv, { force: true })
      }),
    createAgentSession: (harnessId, cwd, sink, account, toolGateway, sessionOptions) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        const events = createSessionEmitter()
        const created = yield* provider.createSession(
          definition,
          cwd,
          events.emit,
          account,
          toolGateway,
          sessionOptions
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
        const timeoutMs = 15_000
        const created = yield* provider
          .createSession(
            definition,
            cwd,
            /* v8 ignore next */
            () => Promise.resolve(),
            account,
            undefined,
            {
              modelListTimeoutMs: Math.max(3_000, timeoutMs - 3_000),
              skillListTimeoutMs: 2_000,
              ...(configSelections === undefined ? {} : { configSelections })
            }
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
        const unapplied: Record<string, string> = {}
        const reconcile = provider.reconcileConfigValue
        for (const [configId, value] of selections) {
          const option = configOptions.find((candidate) => candidate.id === configId)
          const target =
            option === undefined ? undefined : placeConfigValue(option, value, reconcile)
          if (target === undefined) {
            unapplied[configId] = value
            continue
          }
          if (option?.currentValue === target) continue
          configOptions = yield* created.handle.setConfigOption(configId, target).pipe(
            Effect.catchCause((cause) => {
              console.error(
                `[agent-runtime] inspectHarness(${harnessId}) could not apply ${configId}=${target}: ${Cause.pretty(cause)}`
              )
              unapplied[configId] = value
              return Effect.succeed(configOptions)
            })
          )
        }
        void Effect.runPromise(created.handle.close).catch(() => undefined)
        return {
          ...created.metadata,
          configOptions,
          ...(Object.keys(unapplied).length === 0 ? {} : { unappliedConfigSelections: unapplied })
        }
      }),
    loadedAgentSessionIds: () => [...sessions.keys()],
    loadAgentSession: (
      harnessId,
      agentSessionId,
      cwd,
      sink,
      account,
      toolGateway,
      sessionOptions
    ) =>
      adapterPromise("loadAgentSession", () =>
        withSessionLifecycle(agentSessionId, async () => {
          const existing = sessions.get(agentSessionId)
          if (
            existing !== undefined &&
            existing.harnessId === harnessId &&
            existing.cwd === cwd &&
            existing.harnessAccountId === account?.id
          ) {
            existing.sink = sink
            return existing.metadata
          }

          if (existing !== undefined) {
            await existing.chain
            if (sessions.get(agentSessionId) === existing) {
              sessions.delete(agentSessionId)
            }
            await Effect.runPromise(existing.handle.close).catch(() => undefined)
          }

          const { definition, provider } = await Effect.runPromise(definitionFor(harnessId))
          const events = createSessionEmitter()
          const loaded = await Effect.runPromise(
            provider.loadSession(
              definition,
              agentSessionId,
              cwd,
              events.emit,
              account,
              toolGateway,
              sessionOptions
            )
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
