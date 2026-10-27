import { randomUUID } from "node:crypto"

import {
  adapterPromise,
  runtimeError,
  runtimeEffect,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type CreatedAgentSession,
  type CreateSessionOptions,
  type HarnessDefinition,
  type HarnessAccountContext,
  withoutEnv,
  type LoadedAgentSession,
  type ProviderEnvironment,
  type PromptInput,
  type ProviderId,
  type QuestionAnswer,
  type RuntimeEmit,
  type SetGoalUpdate,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { isoTimestamp, type Harness, type HarnessUsageLimits } from "@codevisor/api"
import { Effect } from "effect"

import type { AcpAgentConnection, AcpConnector, AcpPromptResult } from "./connection.js"
import { turnLifecycleEvent } from "./internal.js"
import { makeStdioAcpConnectorWithOptions } from "./stdio-connector.js"

interface ResolvedLaunch {
  readonly command: string
  readonly args: ReadonlyArray<string>
}

const missingRequiredBinary = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment
): string | undefined =>
  definition.requiredBinaries?.find(
    (binary) => !environment.executableExists(binary, environment.env)
  )

const installedBinary = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment
): string | undefined =>
  [...definition.detectBinaries, ...(definition.fallbackPaths ?? [])].find((binary) =>
    environment.executableExists(binary, environment.env)
  )

const locateFallbackBinary = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment,
  installed: string
): string | undefined => {
  if (definition.detectBinaries.includes(installed)) return undefined
  return environment.locateExecutable(installed, environment.env)
}

const resolveLaunch = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment
): ResolvedLaunch | undefined => {
  const launch = definition.launch
  if (launch === undefined || missingRequiredBinary(definition, environment) !== undefined) {
    return undefined
  }
  const installed = installedBinary(definition, environment)
  if (installed === undefined) {
    return undefined
  }
  switch (launch.kind) {
    case "npx": {
      const command =
        environment.locateExecutable("npx", environment.env) ??
        (environment.executableExists("npx", environment.env) ? "npx" : undefined)
      return command === undefined
        ? undefined
        : { args: ["-y", launch.packageName, ...launch.args], command }
    }
    default: {
      const located =
        environment.locateExecutable(launch.command, environment.env) ??
        locateFallbackBinary(definition, environment, installed)
      if (located !== undefined) {
        return { args: launch.args, command: located }
      }
      /* v8 ignore next 3 */
      if (environment.executableExists(launch.command, environment.env)) {
        return { args: launch.args, command: launch.command }
      }
      /* v8 ignore next */
      return undefined
    }
  }
}

const unavailableReadiness = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment
): Harness["readiness"] => {
  if (installedBinary(definition, environment) === undefined) {
    return { detail: "CLI not found on PATH", state: "unavailable" }
  }
  const missing = missingRequiredBinary(definition, environment)
  if (missing !== undefined) return { detail: `Requires ${missing}`, state: "unavailable" }
  /* v8 ignore next 3 */
  if (definition.launch?.kind === "npx") {
    return { detail: "Requires npx", state: "unavailable" }
  }
  /* v8 ignore next 2 */
  const command =
    definition.launch?.kind === "executable" ? definition.launch.command : definition.id
  return { detail: `${command} not found on PATH`, state: "unavailable" }
}

export interface AcpLaunchContext {
  readonly toolGateway?: ToolGatewayConfig
}

export interface AcpProviderConfig {
  readonly providerId?: ProviderId
  readonly connector?: AcpConnector
  readonly launchEnv?: (env: NodeJS.ProcessEnv, launch: AcpLaunchContext) => NodeJS.ProcessEnv
  readonly readUsageLimits?: (
    connection: AcpAgentConnection,
    definition: HarnessDefinition
  ) => Effect.Effect<HarnessUsageLimits, AgentRuntimeError>
}

const skillGraceMs = 250

const skillListTimeoutMs = (sessionOptions: CreateSessionOptions | undefined): number =>
  sessionOptions?.skillListTimeoutMs ?? skillGraceMs

const authProbeTimeoutMs = 10_000

const usageLimitsTimeoutMs = 15_000

const unavailableUsageLimits = (harnessId: string, detail: string): HarnessUsageLimits => ({
  detail,
  fetchedAt: isoTimestamp(),
  harnessId,
  state: "unavailable",
  windows: []
})

const withSignInDetail = (result: AcpPromptResult, harnessName: string): AcpPromptResult => {
  if (result.stopKind !== "authRequired" || result.stopDetail !== undefined) return result
  return { ...result, stopDetail: `${harnessName} isn't signed in. Sign in to continue.` }
}

const acpSessionHandle = (
  connection: AcpAgentConnection,
  sessionId: string,
  emit: RuntimeEmit,
  harnessName: string,
  account?: HarnessAccountContext
): AgentSessionHandle => ({
  ...(connection.canLoadSession === false ? { resumable: false } : {}),
  prompt: (input) =>
    Effect.gen(function* () {
      if (account?.beforeTurn !== undefined) {
        const beforeTurn = account.beforeTurn
        yield* Effect.promise(() => beforeTurn().catch(() => undefined))
      }
      const turnId = randomUUID()
      yield* adapterPromise("promptTurnStart", () =>
        emit(turnLifecycleEvent(sessionId, turnId, "started"))
      )
      const result = yield* connection.prompt(sessionId, input)
      yield* adapterPromise("promptTurnEnd", () =>
        emit(turnLifecycleEvent(sessionId, turnId, "ended", withSignInDetail(result, harnessName)))
      )
      return result
    }),
  cancel: Effect.gen(function* () {
    yield* connection.cancel(sessionId)
    yield* adapterPromise("cancelTurnEnd", () =>
      emit(turnLifecycleEvent(sessionId, randomUUID(), "ended", { stopReason: "cancelled" }))
    )
    return { runtimeState: "reusable" as const }
  }),
  setMode: (modeId) =>
    Effect.gen(function* () {
      yield* connection.setMode(sessionId, modeId)
      yield* adapterPromise("setModeEvent", () =>
        emit({ kind: "session.updated", subjectId: sessionId, payload: { modeId } })
      )
    }),
  setConfigOption: (configId, value) =>
    Effect.gen(function* () {
      const configOptions = yield* connection.setConfigOption(sessionId, configId, value)
      yield* adapterPromise("setConfigOptionEvent", () =>
        emit({
          kind: "session.updated",
          subjectId: sessionId,
          payload: { configId, configOptions, value }
        })
      )
      return configOptions
    }),
  ...(connection.steer === undefined
    ? {}
    : {
        steer: (input: string | PromptInput) => connection.steer!(sessionId, input)
      }),
  ...(connection.answerQuestion === undefined
    ? {}
    : {
        answerQuestion: (questionId: string, answer: QuestionAnswer) =>
          connection.answerQuestion!(sessionId, questionId, answer)
      }),
  ...(connection.replyToQuestion === undefined
    ? {}
    : {
        replyToQuestion: (questionId: string, reply: PromptInput) =>
          connection.replyToQuestion!(sessionId, questionId, reply)
      }),
  ...(connection.setGoal === undefined
    ? {}
    : {
        setGoal: (update: SetGoalUpdate) => connection.setGoal!(sessionId, update)
      }),
  ...(connection.clearGoal === undefined
    ? {}
    : {
        clearGoal: connection.clearGoal(sessionId)
      }),
  close: connection.close
})

export const makeAcpProvider = (
  environment: ProviderEnvironment,
  config: AcpProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? makeStdioAcpConnectorWithOptions()
  const launchEnv = config.launchEnv ?? ((env: NodeJS.ProcessEnv) => env)

  const connect = (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ): Effect.Effect<AcpAgentConnection, AgentRuntimeError> =>
    Effect.gen(function* () {
      const launch = yield* runtimeEffect("resolveHarness", () => {
        const resolved = resolveLaunch(definition, environment)
        if (resolved === undefined) {
          throw new Error(`ACP harness is unavailable: ${definition.id}`)
        }
        return resolved
      })
      const env = yield* adapterPromise("resolveEnvironment", () => environment.envFor(cwd))
      return yield* connector.connect(
        {
          args: launch.args,
          command: launch.command,
          cwd,
          env: launchEnv(
            {
              ...withoutEnv(env, account?.unsetEnv),
              ...(definition.launch?.kind === "executable" ? definition.launch.env : undefined),
              ...account?.env
            },
            toolGateway === undefined ? {} : { toolGateway }
          ),
          harnessId: definition.id
        },
        emit
      )
    })

  const readUsage = config.readUsageLimits
  return {
    id: config.providerId ?? "acp",
    readiness: (definition) => {
      if (resolveLaunch(definition, environment) === undefined) {
        return unavailableReadiness(definition, environment)
      }
      return { state: "ready" }
    },
    createSession: (
      definition,
      cwd,
      emit,
      account,
      toolGateway,
      sessionOptions
    ): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
      Effect.gen(function* () {
        const connection = yield* connect(definition, cwd, emit, account, toolGateway)
        return yield* connection
          .createSession(cwd, toolGateway, skillListTimeoutMs(sessionOptions))
          .pipe(
            Effect.map((metadata) => ({
              handle: acpSessionHandle(
                connection,
                metadata.sessionId,
                emit,
                definition.name,
                account
              ),
              metadata
            })),
            Effect.onError(() => connection.close.pipe(Effect.ignoreCause))
          )
      }),
    loadSession: (
      definition,
      agentSessionId,
      cwd,
      emit,
      account,
      toolGateway,
      sessionOptions
    ): Effect.Effect<LoadedAgentSession, AgentRuntimeError> =>
      Effect.gen(function* () {
        const connection = yield* connect(definition, cwd, emit, account, toolGateway)
        return yield* connection
          .loadSession(agentSessionId, cwd, toolGateway, skillListTimeoutMs(sessionOptions))
          .pipe(
            Effect.map((metadata) => ({
              handle: acpSessionHandle(
                connection,
                metadata.sessionId,
                emit,
                definition.name,
                account
              ),
              metadata,
              sessionId: metadata.sessionId
            })),
            Effect.onError(() => connection.close.pipe(Effect.ignoreCause))
          )
      }),
    listAgentSessions: async (definition, account) => {
      try {
        return await Effect.runPromise(
          Effect.gen(function* () {
            const connection = yield* connect(
              definition,
              process.cwd(),
              () => Promise.resolve(),
              account
            )
            const sessions = connection.listSessions ?? Effect.succeed([])
            return yield* sessions.pipe(Effect.ensuring(connection.close.pipe(Effect.ignoreCause)))
          })
        )
      } catch {
        return []
      }
    },
    ...(readUsage === undefined
      ? {}
      : {
          readUsageLimits: (
            definition: HarnessDefinition,
            cwd: string,
            account?: HarnessAccountContext
          ) =>
            Effect.gen(function* () {
              const connection = yield* connect(definition, cwd, () => Promise.resolve(), account)
              return yield* readUsage(connection, definition).pipe(
                Effect.timeout(usageLimitsTimeoutMs),
                Effect.ensuring(connection.close.pipe(Effect.ignoreCause))
              )
            }).pipe(
              Effect.catch((cause) =>
                Effect.succeed(
                  unavailableUsageLimits(
                    definition.id,
                    cause instanceof Error
                      ? cause.message
                      : `${definition.name} usage limits are unavailable.`
                  )
                )
              )
            )
        }),
    probeAuth: (definition, account) =>
      Effect.gen(function* () {
        const connection = yield* connect(
          definition,
          process.cwd(),
          () => Promise.resolve(),
          account
        )
        return yield* connection.probeAuth(process.cwd()).pipe(
          Effect.timeout(authProbeTimeoutMs),
          Effect.mapError((cause) =>
            runtimeError(
              "probeAuth",
              cause._tag === "TimeoutError"
                ? new Error(`ACP authentication probe timed out after ${authProbeTimeoutMs}ms`)
                : cause
            )
          ),
          Effect.ensuring(connection.close.pipe(Effect.ignoreCause))
        )
      }),
    authenticate: (definition, methodId, account) =>
      Effect.gen(function* () {
        const connection = yield* connect(
          definition,
          process.cwd(),
          () => Promise.resolve(),
          account
        )
        yield* connection
          .authenticate(methodId)
          .pipe(Effect.ensuring(connection.close.pipe(Effect.ignoreCause)))
      }),
    logout: (definition, account) =>
      Effect.gen(function* () {
        const connection = yield* connect(
          definition,
          process.cwd(),
          () => Promise.resolve(),
          account
        )
        yield* connection.logout.pipe(Effect.ensuring(connection.close.pipe(Effect.ignoreCause)))
      })
  }
}
