import { randomUUID } from "node:crypto"

import type { BackgroundTerminalIntegration } from "@codevisor/agent-runtime"
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
  type ProviderId,
  type QuestionAnswer,
  type RuntimeEmit,
  type SetGoalUpdate,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import type { Harness, SessionConfigOption } from "@codevisor/api"
import { Effect } from "effect"

import type { AcpAgentConnection, AcpConnector } from "./connection.js"
import { turnLifecycleEvent } from "./internal.js"
import { makeStdioAcpConnector } from "./stdio-connector.js"

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

/// The first detect binary or installer location that exists. A login
/// shell that skips ~/.bashrc misses the PATH entry an installer added there,
/// so a harness's own install directory counts too.
const installedBinary = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment
): string | undefined =>
  [...definition.detectBinaries, ...(definition.fallbackPaths ?? [])].find((binary) =>
    environment.executableExists(binary, environment.env)
  )

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
    case "executable": {
      const located =
        environment.locateExecutable(launch.command, environment.env) ??
        (definition.detectBinaries.includes(installed)
          ? undefined
          : environment.locateExecutable(installed, environment.env))
      if (located !== undefined) {
        return { args: launch.args, command: located }
      }
      /* v8 ignore next 3 -- installed executable catalog entries currently use the launch command as their detect binary. */
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
  /* v8 ignore next 3 -- installed executable catalog entries are ready before unavailableReadiness is called. */
  if (definition.launch?.kind === "npx") {
    return { detail: "Requires npx", state: "unavailable" }
  }
  /* v8 ignore next 2 */
  const command =
    definition.launch?.kind === "executable" ? definition.launch.command : definition.id
  return { detail: `${command} not found on PATH`, state: "unavailable" }
}

/// What a launch is for: a chat session gets the tool gateway; auth probes
/// and session listing don't.
export interface AcpLaunchContext {
  readonly toolGateway?: ToolGatewayConfig
}

export interface AcpProviderConfig {
  /// Provider identity for an ACP-backed native adapter. The generic provider
  /// keeps `acp`; packages that compose its transport register their own id.
  readonly providerId?: ProviderId
  readonly connector?: AcpConnector
  /// When set, the client advertises the ACP `terminal` capability and backs
  /// `terminal/*` with server-owned processes (surfaced as terminal tabs once
  /// they outlive the promotion delay).
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  /// Adjusts the agent's environment at launch, after the account's.
  readonly launchEnv?: (env: NodeJS.ProcessEnv, launch: AcpLaunchContext) => NodeJS.ProcessEnv
}

/// How long session setup waits for the skills an agent pushes right after
/// it (most send them on the next tick). Events emitted while setup is still
/// running never reach the runtime, so the metadata has to carry them; a
/// later list still arrives as session output.
const skillGraceMs = 250

const skillListTimeoutMs = (sessionOptions: CreateSessionOptions | undefined): number =>
  sessionOptions?.skillListTimeoutMs ?? skillGraceMs

/// Bounds the authentication-only ACP session used during discovery. Some
/// agents accept initialize but never answer session/new; discovery must
/// still settle and tear down their process.
const authProbeTimeoutMs = 10_000

export const makeAcpProvider = (
  environment: ProviderEnvironment,
  config: AcpProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? makeStdioAcpConnector(config.backgroundTerminals)
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
      return yield* connector.connect(
        {
          args: launch.args,
          command: launch.command,
          cwd,
          env: launchEnv(
            {
              ...withoutEnv(environment.env, account?.unsetEnv),
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

  const handleFor = (
    connection: AcpAgentConnection,
    sessionId: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext
  ): AgentSessionHandle => ({
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
          emit(
            turnLifecycleEvent(
              sessionId,
              turnId,
              "ended",
              result.stopReason,
              result.stopDetail,
              result.retryable
            )
          )
        )
        return result
      }),
    cancel: Effect.gen(function* () {
      yield* connection.cancel(sessionId)
      // Cancelling without a locally tracked prompt can otherwise leave a
      // replayed assistant chunk generating forever. A terminal event is
      // idempotent if the prompt also resolves with its own cancellation event.
      yield* adapterPromise("cancelTurnEnd", () =>
        emit(turnLifecycleEvent(sessionId, randomUUID(), "ended", "cancelled"))
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
        return configOptions as ReadonlyArray<SessionConfigOption>
      }),
    ...(connection.answerQuestion === undefined
      ? {}
      : {
          answerQuestion: (questionId: string, answer: QuestionAnswer) =>
            connection.answerQuestion!(sessionId, questionId, answer)
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

  return {
    id: config.providerId ?? "acp",
    readiness: (definition) =>
      resolveLaunch(definition, environment) === undefined
        ? unavailableReadiness(definition, environment)
        : { state: "ready" },
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
              handle: handleFor(connection, metadata.sessionId, emit, account),
              metadata
            })),
            // A failed or interrupted setup never enters the runtime's managed
            // session map, so the provider owns cleaning up its process.
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
              handle: handleFor(connection, metadata.sessionId, emit, account),
              metadata,
              sessionId: metadata.sessionId
            })),
            // Like createSession: a session that never loads is never managed,
            // so its agent process is ours to close.
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
        // Older/non-conforming adapters may not implement session/list. Keep
        // the previous empty discovery result rather than failing imports.
        return []
      }
    },
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
