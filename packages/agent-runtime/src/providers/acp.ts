import * as acp from "@agentclientprotocol/sdk"
import type {
  ContentBlock as AcpContentBlock,
  NewSessionResponse,
  SessionConfigOption as AcpSessionConfigOption,
  SessionConfigSelectGroup as AcpSessionConfigSelectGroup,
  SessionConfigSelectOption as AcpSessionConfigSelectOption,
  SessionMode as AcpSessionMode,
  SessionModeState as AcpSessionModeState
} from "@agentclientprotocol/sdk"
import type {
  CanonicalModeId,
  GoalStatus,
  Harness,
  QuestionSpec,
  SessionConfigOption,
  SessionConfigSelectGroup,
  SessionConfigSelectOption,
  SessionGoal,
  SessionModeState
} from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { spawn } from "node:child_process"
import type { ChildProcessWithoutNullStreams } from "node:child_process"
import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { Readable, Writable } from "node:stream"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import { Effect } from "effect"
import type { BackgroundTerminalIntegration } from "../background-terminals.js"
import { diffStatsFromTexts } from "../diff-stats.js"
import type { AgentSessionSummary } from "../agent-sessions.js"
import type { DiffStat } from "@codevisor/api"
import { makeAcpTerminalHost, type AcpTerminalHost } from "./acp-terminals.js"
import {
  adapterPromise,
  normalizePromptInput,
  runtimeError,
  runtimeEffect,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type AgentSessionMetadata,
  type CreatedAgentSession,
  type HarnessDefinition,
  type HarnessAccountContext,
  type LoadedAgentSession,
  type PromptInput,
  type ProviderEnvironment,
  type QuestionAnswer,
  type RuntimeEmit,
  type RuntimeEvent,
  type SetGoalUpdate,
  type ToolGatewayConfig
} from "../types.js"

export const acpProtocolVersion = acp.PROTOCOL_VERSION

export interface AcpHarnessLaunchRequest {
  readonly harnessId: string
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

/// One live ACP adapter process. Session output is pushed to the `emit`
/// callback for the connection's whole lifetime — including notifications
/// that arrive between turns — which is what keeps background/agent-initiated
/// work from being dropped.
export interface AcpAgentConnection {
  readonly listSessions?: Effect.Effect<ReadonlyArray<AgentSessionSummary>, AgentRuntimeError>
  readonly createSession: (
    cwd: string,
    toolGateway?: ToolGatewayConfig
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly loadSession: (
    sessionId: string,
    cwd: string,
    toolGateway?: ToolGatewayConfig
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly prompt: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<
    { readonly stopReason: string; readonly stopDetail?: string },
    AgentRuntimeError
  >
  readonly cancel: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  /// Returns the agent's updated config options in Codevisor's normalized
  /// shape so the caller can broadcast them.
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<unknown, AgentRuntimeError>
  readonly setGoal?: (
    sessionId: string,
    update: SetGoalUpdate
  ) => Effect.Effect<SessionGoal, AgentRuntimeError>
  readonly clearGoal?: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  /// Resolves a pending `session/request_permission` that was surfaced as a
  /// blocking question. Absent on connections without permission plumbing
  /// (fakes, older transports) — the runtime then reports unsupported.
  readonly answerQuestion?: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly probeAuth: (cwd: string) => Effect.Effect<
    {
      readonly state: "authenticated" | "unauthenticated" | "notRequired" | "error"
      readonly methods: ReadonlyArray<{
        readonly id: string
        readonly name: string
        readonly description?: string
      }>
      readonly canLogout: boolean
      readonly detail?: string
    },
    AgentRuntimeError
  >
  readonly authenticate: (methodId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly logout: Effect.Effect<void, AgentRuntimeError>
  readonly close: Effect.Effect<void, AgentRuntimeError>
}

export interface AcpConnector {
  readonly connect: (
    request: AcpHarnessLaunchRequest,
    emit: RuntimeEmit
  ) => Effect.Effect<AcpAgentConnection, AgentRuntimeError>
}

interface ResolvedLaunch {
  readonly command: string
  readonly args: ReadonlyArray<string>
}

const resolveLaunch = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment
): ResolvedLaunch | undefined => {
  const launch = definition.launch
  if (launch === undefined) {
    return undefined
  }
  if (
    !definition.detectBinaries.some((binary) =>
      environment.executableExists(binary, environment.env)
    )
  ) {
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
      const located = environment.locateExecutable(launch.command, environment.env)
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
  const installed = definition.detectBinaries.some((binary) =>
    environment.executableExists(binary, environment.env)
  )
  if (!installed) {
    return { detail: "CLI not found on PATH", state: "unavailable" }
  }
  /* v8 ignore next 3 -- installed executable catalog entries are ready before unavailableReadiness is called. */
  if (definition.launch?.kind === "npx") {
    return { detail: "Requires npx", state: "unavailable" }
  }
  /* v8 ignore next 2 */
  const command =
    definition.launch?.kind === "executable" ? definition.launch.command : definition.id
  return { detail: `${command} not found on PATH`, state: "unavailable" }
}

export interface AcpProviderConfig {
  readonly connector?: AcpConnector
  /// Bounds the authentication-only ACP session used during discovery. Some
  /// agents accept initialize but never answer session/new; discovery must
  /// still settle and tear down their process.
  readonly authProbeTimeoutMs?: number
  /// Bounds the ACP initialize handshake for stdio agents.
  readonly connectTimeoutMs?: number
  /// When set, the client advertises the ACP `terminal` capability and backs
  /// `terminal/*` with server-owned processes (surfaced as terminal tabs once
  /// they outlive the promotion delay).
  readonly backgroundTerminals?: BackgroundTerminalIntegration
}

export const makeAcpProvider = (
  environment: ProviderEnvironment,
  config: AcpProviderConfig = {}
): AgentProvider => {
  const authProbeTimeoutMs = config.authProbeTimeoutMs ?? 10_000
  const connector =
    config.connector ?? makeStdioAcpConnector(config.backgroundTerminals, config.connectTimeoutMs)

  const connect = (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext
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
          env: { ...environment.env, ...account?.env },
          harnessId: definition.id
        },
        emit
      )
    })

  const handleFor = (
    connection: AcpAgentConnection,
    sessionId: string,
    emit: RuntimeEmit
  ): AgentSessionHandle => ({
    prompt: (input) =>
      Effect.gen(function* () {
        const turnId = randomUUID()
        yield* adapterPromise("promptTurnStart", () =>
          emit(turnLifecycleEvent(sessionId, turnId, "started"))
        )
        const result = yield* connection.prompt(sessionId, input)
        yield* adapterPromise("promptTurnEnd", () =>
          emit(turnLifecycleEvent(sessionId, turnId, "ended", result.stopReason, result.stopDetail))
        )
        return result
      }),
    cancel: Effect.gen(function* () {
      yield* connection.cancel(sessionId)
      // Cancelling without a locally tracked prompt can otherwise leave a
      // replayed assistant chunk generating forever (notably after a Grok
      // goal was cleared). A terminal event is idempotent if the prompt also
      // resolves with its own cancellation event.
      yield* adapterPromise("cancelTurnEnd", () =>
        emit(turnLifecycleEvent(sessionId, randomUUID(), "ended", "cancelled"))
      )
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
    id: "acp",
    readiness: (definition) =>
      resolveLaunch(definition, environment) === undefined
        ? unavailableReadiness(definition, environment)
        : { state: "ready" },
    createSession: (
      definition,
      cwd,
      emit,
      account,
      toolGateway
    ): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
      Effect.gen(function* () {
        const connection = yield* connect(definition, cwd, emit, account)
        return yield* connection.createSession(cwd, toolGateway).pipe(
          Effect.map((metadata) => ({
            handle: handleFor(connection, metadata.sessionId, emit),
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
      toolGateway
    ): Effect.Effect<LoadedAgentSession, AgentRuntimeError> =>
      Effect.gen(function* () {
        const connection = yield* connect(definition, cwd, emit, account)
        const metadata = yield* connection.loadSession(agentSessionId, cwd, toolGateway)
        return {
          handle: handleFor(connection, metadata.sessionId, emit),
          metadata,
          sessionId: metadata.sessionId
        }
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

const turnLifecycleEvent = (
  sessionId: string,
  turnId: string,
  turnState: "started" | "ended",
  stopReason?: string,
  stopDetail?: string
): RuntimeEvent => ({
  kind: "session.updated",
  subjectId: sessionId,
  payload: {
    initiatedBy: "user",
    turnId,
    turnState,
    ...(stopReason === undefined ? {} : { stopReason }),
    ...(stopDetail === undefined ? {} : { stopDetail })
  }
})

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
export const makeStdioAcpConnector = (
  backgroundTerminals?: BackgroundTerminalIntegration,
  connectTimeoutMs = 10_000
): AcpConnector => ({
  connect: (request, emit) =>
    adapterPromise("connect", async () => {
      const child = spawn(request.command, [...request.args], {
        cwd: request.cwd,
        // Some CLIs spawn worker descendants. A separate process group lets
        // close/timeout reliably terminate the whole ACP tree.
        detached: process.platform !== "win32",
        env: request.env,
        stdio: ["pipe", "pipe", "pipe"]
      })
      const terminate = processGroupTerminator(child)
      let closeConnection: ((error: Error) => void) | undefined
      const spawnFailure = new Promise<never>((_resolve, reject) => {
        child.once("error", (error) => {
          closeConnection?.(error)
          reject(error)
        })
      })
      spawnFailure.catch(() => undefined)
      const stderr = captureStderr(child)
      const pendingQuestions = new Map<string, PendingAcpQuestion>()
      const piStartupInfoBySession = new Map<string, string>()
      const grokGoals = new Map<string, SessionGoal>()
      const safeEmit = (event: RuntimeEvent): void => {
        void emit(event).catch(() => undefined)
      }
      const terminals =
        backgroundTerminals === undefined
          ? undefined
          : makeAcpTerminalHost({
              commandMode: request.harnessId === "grok-build" ? "shell" : "argv",
              emit,
              env: request.env,
              integration: backgroundTerminals
            })
      const emitQuestionResolved = (
        questionId: string,
        pending: PendingAcpQuestion,
        outcome: "answered" | "cancelled",
        answers: QuestionAnswer["answers"]
      ): void => {
        safeEmit({
          kind: "session.output",
          payload: {
            outcome,
            questionId,
            questions: pending.questions,
            sessionUpdate: "question_resolved",
            ...(answers === undefined ? {} : { answers })
          },
          subjectId: pending.sessionId
        })
      }
      const enqueueQuestion = <Response>(
        question: GrokMappedQuestion<Response>
      ): Promise<Response> => {
        const questionId = randomUUID()
        if (question.planDocument !== undefined) {
          safeEmit({
            kind: "session.output",
            payload: { markdown: question.planDocument, sessionUpdate: "plan_document" },
            subjectId: question.sessionId
          })
        }
        safeEmit({
          kind: "session.output",
          payload: {
            questionId,
            questions: question.questions,
            sessionUpdate: "question"
          },
          subjectId: question.sessionId
        })
        return new Promise<Response>((resolve) => {
          pendingQuestions.set(questionId, {
            cancelledResponse: question.cancelledResponse,
            questions: question.questions,
            resolve: (response) => resolve(response as Response),
            responseFor: question.responseFor,
            sessionId: question.sessionId
          })
        })
      }
      const connection = createClientApp(
        (notification) => {
          const startupInfo = piStartupInfoBySession.get(notification.sessionId)
          if (
            request.harnessId === "pi" &&
            startupInfo !== undefined &&
            isPiStartupInfoNotification(notification, startupInfo)
          ) {
            piStartupInfoBySession.delete(notification.sessionId)
            return
          }
          safeEmit(runtimeEventFromNotification(notification))
        },
        (params) => {
          const question = acpPermissionQuestion(params)
          if (question === undefined) {
            return Promise.resolve({ outcome: { outcome: "cancelled" as const } })
          }
          return enqueueQuestion({
            sessionId: question.sessionId,
            questions: [question.spec],
            ...(question.planDocument === undefined ? {} : { planDocument: question.planDocument }),
            cancelledResponse: { outcome: { outcome: "cancelled" as const } },
            responseFor: (answer) => acpPermissionOutcome(question.optionIds, answer)
          })
        },
        terminals,
        request.harnessId === "grok-build"
          ? {
              requestPlanApproval: (params) => {
                const question = grokPlanApprovalQuestion(params)
                return question === undefined
                  ? Promise.resolve({ outcome: "cancelled" as const })
                  : enqueueQuestion(question)
              },
              askUserQuestion: (params) => {
                const question = grokAskUserQuestion(params)
                return question === undefined
                  ? Promise.resolve({ outcome: "cancelled" as const })
                  : enqueueQuestion(question)
              },
              onSessionNotification: (params) => {
                const mapped = grokGoalNotification(params, (sessionId) => grokGoals.get(sessionId))
                if (mapped === undefined) return
                if (mapped.goal === undefined) {
                  grokGoals.delete(mapped.sessionId)
                } else {
                  grokGoals.set(mapped.sessionId, mapped.goal)
                }
                safeEmit(mapped.event)
              }
            }
          : undefined
      ).connect(
        acp.ndJsonStream(
          Writable.toWeb(child.stdin) as WritableStream<Uint8Array>,
          Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>
        )
      )
      const answerQuestion = async (
        sessionId: string,
        questionId: string,
        answer: QuestionAnswer
      ): Promise<void> => {
        const pending = pendingQuestions.get(questionId)
        if (pending === undefined || pending.sessionId !== sessionId) {
          throw new Error(`No pending question: ${questionId}`)
        }
        pendingQuestions.delete(questionId)
        pending.resolve(pending.responseFor(answer))
        emitQuestionResolved(
          questionId,
          pending,
          answer.outcome === "answered" ? "answered" : "cancelled",
          answer.outcome === "answered" ? answer.answers : undefined
        )
      }
      /// ACP spec: a cancelled turn (and a closing connection) must resolve
      /// pending permission requests as cancelled.
      const cancelQuestions = (sessionId: string | undefined): void => {
        for (const [questionId, pending] of pendingQuestions) {
          if (sessionId !== undefined && pending.sessionId !== sessionId) continue
          pendingQuestions.delete(questionId)
          pending.resolve(pending.cancelledResponse)
          emitQuestionResolved(questionId, pending, "cancelled", undefined)
        }
      }
      closeConnection = (error) => {
        cancelQuestions(undefined)
        terminals?.closeAll()
        connection.close(error)
      }
      child.once("exit", () => {
        cancelQuestions(undefined)
        terminals?.closeAll()
        connection.close(new Error(stderr()))
      })
      let initialized: acp.InitializeResponse
      try {
        initialized = await promiseWithTimeout(
          Promise.race([
            connection.agent.request(acp.methods.agent.initialize, {
              clientCapabilities: {
                plan: {},
                terminal: terminals !== undefined
              },
              clientInfo: {
                name: "Codevisor",
                title: "Codevisor",
                version: "0.1.0"
              },
              protocolVersion: acp.PROTOCOL_VERSION
            }),
            spawnFailure
          ]),
          connectTimeoutMs,
          `ACP initialize timed out after ${connectTimeoutMs}ms`
        )
      } catch (cause) {
        const error = cause instanceof Error ? cause : new Error(String(cause))
        closeConnection(error)
        terminate()
        throw error
      }
      return sdkConnection(
        connection,
        stderr,
        () => {
          cancelQuestions(undefined)
          terminals?.closeAll()
          terminate()
        },
        initialized?.agentCapabilities?.promptCapabilities ?? {},
        { answerQuestion, cancelQuestions },
        {
          methods: (initialized?.authMethods ?? []).map((method) => ({
            id: method.id,
            name: method.name,
            ...(method.description == null ? {} : { description: method.description })
          })),
          canLogout: initialized?.agentCapabilities?.auth?.logout != null
        },
        request.harnessId === "pi" ? piStartupInfoBySession : undefined,
        request.harnessId === "pi"
          ? (sessionId) => readPiSessionError(sessionId, request.env.HOME ?? homedir())
          : undefined,
        request.harnessId,
        grokGoals,
        safeEmit
      )
    })
})

const promiseWithTimeout = <A>(
  promise: Promise<A>,
  timeoutMs: number,
  message: string
): Promise<A> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(message)), timeoutMs)
    timer.unref()
  })
  return Promise.race([promise, timeout]).finally(() => {
    if (timer !== undefined) clearTimeout(timer)
  })
}

const processGroupTerminator = (child: ChildProcessWithoutNullStreams): (() => void) => {
  let terminated = false
  return () => {
    if (terminated) return
    terminated = true
    const pid = child.pid
    if (pid === undefined || process.platform === "win32") {
      child.kill()
      return
    }
    try {
      process.kill(-pid, "SIGTERM")
    } catch {
      child.kill()
    }
    const forceKill = setTimeout(() => {
      try {
        process.kill(-pid, "SIGKILL")
      } catch {
        // The process group already exited.
      }
    }, 1_000)
    forceKill.unref()
  }
}

export const stdioAcpConnector: AcpConnector = makeStdioAcpConnector()

export interface AcpPromptCapabilities {
  readonly image?: boolean
}

/// Builds the session/prompt content blocks. Every attachment is surfaced as a
/// `resource_link` — the ACP baseline that all agents must support — pointing
/// at its materialized temp file, so any harness (opencode included) can read
/// it from disk. Images are ALSO embedded inline as base64 when the harness
/// declared image support, so multimodal agents see the pixels directly.
/// Exported for unit tests — the live wiring runs inside the stdio SDK connection.
export const acpPrompt = (
  input: PromptInput,
  capabilities: AcpPromptCapabilities
): Array<AcpContentBlock> => {
  const attachments = input.attachments ?? []
  const blocks: Array<AcpContentBlock> = []
  if (input.text !== "" || attachments.length === 0) {
    blocks.push({ text: input.text, type: "text" })
  }
  for (const attachment of attachments) {
    blocks.push({
      mimeType: attachment.mimeType,
      name: attachment.name,
      size: attachment.data.length,
      type: "resource_link",
      uri: pathToFileURL(attachment.path).href
    })
    if (attachment.kind === "image" && capabilities.image === true) {
      blocks.push({
        data: attachment.data.toString("base64"),
        mimeType: attachment.mimeType,
        type: "image"
      })
    }
  }
  return blocks
}

interface AcpQuestionControls {
  readonly answerQuestion: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Promise<void>
  readonly cancelQuestions: (sessionId: string | undefined) => void
}

interface AcpGrokControls {
  readonly requestPlanApproval: (params: unknown) => Promise<GrokPlanApprovalResponse>
  readonly askUserQuestion: (params: unknown) => Promise<GrokAskUserQuestionResponse>
  readonly onSessionNotification: (params: unknown) => void
}

interface AcpAuthControls {
  readonly methods: ReadonlyArray<{
    readonly id: string
    readonly name: string
    readonly description?: string
  }>
  readonly canLogout: boolean
}

const sdkConnection = (
  connection: acp.ClientConnection,
  stderr: () => string,
  terminate: () => void = () => undefined,
  promptCapabilities: AcpPromptCapabilities = {},
  questions?: AcpQuestionControls,
  auth: AcpAuthControls = { methods: [], canLogout: false },
  piStartupInfoBySession?: Map<string, string>,
  piSessionError?: (sessionId: string) => Promise<string | undefined>,
  harnessId?: string,
  grokGoals: Map<string, SessionGoal> = new Map(),
  onGrokGoalEvent: (event: RuntimeEvent) => void = () => undefined
): AcpAgentConnection => {
  connection.closed.catch(() => undefined)

  // Per-session model list from the ACP model-selection extension, cached so a
  // later `session/set_model` can rebuild the picker with the new current value.
  const modelStates = new Map<string, AcpModelState>()
  // Some adapters (notably pi-acp) expose a native select option whose id is
  // also `model`. That must go through standard ACP set_config_option; the
  // optional session/set_model extension is only for agents without a native
  // model option.
  const nativeConfigIds = new Map<string, ReadonlySet<string>>()
  const grokGoalTurns = new Map<string, Promise<void>>()

  const mcpServers = (toolGateway: ToolGatewayConfig | undefined) =>
    toolGateway === undefined
      ? []
      : [
          {
            type: "http" as const,
            name: toolGateway.name,
            url: toolGateway.url,
            headers: [{ name: "Authorization", value: `Bearer ${toolGateway.bearerToken}` }]
          }
        ]

  const runGrokGoalPrompt = (
    sessionId: string,
    prompt: string,
    announceActivity = false
  ): Promise<void> => {
    const turnId = randomUUID()
    onGrokGoalEvent(turnLifecycleEvent(sessionId, turnId, "started"))
    if (announceActivity) {
      onGrokGoalEvent({
        kind: "session.output",
        subjectId: sessionId,
        payload: {
          content: { text: "Starting goal", type: "text" },
          sessionUpdate: "agent_thought_chunk"
        }
      })
    }
    const turn = connection.agent
      .request(acp.methods.agent.session.prompt, {
        prompt: [{ type: "text", text: prompt }],
        sessionId
      })
      .then(
        (response) => {
          onGrokGoalEvent(turnLifecycleEvent(sessionId, turnId, "ended", response.stopReason))
        },
        (cause) => {
          onGrokGoalEvent(turnLifecycleEvent(sessionId, turnId, "ended", "cancelled"))
          throw cause
        }
      )
    grokGoalTurns.set(sessionId, turn)
    void turn
      .catch(() => undefined)
      .finally(() => {
        if (grokGoalTurns.get(sessionId) === turn) grokGoalTurns.delete(sessionId)
      })
    return turn
  }

  const stopGrokGoalTurn = async (sessionId: string): Promise<boolean> => {
    const activeTurn = grokGoalTurns.get(sessionId)
    if (activeTurn === undefined) return false
    questions?.cancelQuestions(sessionId)
    await connection.agent.notify(acp.methods.agent.session.cancel, { sessionId })
    await activeTurn.catch(() => undefined)
    return true
  }

  const currentGoalOrThrow = (sessionId: string): SessionGoal => {
    const current = grokGoals.get(sessionId)
    if (current === undefined) throw new Error("No Grok goal is currently set")
    return current
  }

  return {
    probeAuth: (cwd) =>
      adapterPromise("probeAuth", async () => {
        try {
          await connection.agent.request(acp.methods.agent.session.new, { cwd, mcpServers: [] })
          return {
            state:
              auth.methods.length === 0 ? ("notRequired" as const) : ("authenticated" as const),
            methods: auth.methods,
            canLogout: auth.canLogout
          }
        } catch (cause) {
          const error = cause as { code?: number; message?: string }
          if (
            error.code === -32000 ||
            error.message?.toLowerCase().includes("authentication required")
          ) {
            return {
              state: "unauthenticated" as const,
              methods: auth.methods,
              canLogout: auth.canLogout
            }
          }
          return {
            state: "error" as const,
            methods: auth.methods,
            canLogout: auth.canLogout,
            detail: cause instanceof Error ? cause.message : String(cause)
          }
        }
      }),
    authenticate: (methodId) =>
      adapterPromise("authenticate", async () => {
        await connection.agent.request(acp.methods.agent.authenticate, { methodId })
      }),
    logout: adapterPromise("logout", async () => {
      if (!auth.canLogout) throw new Error("ACP agent did not advertise logout support")
      await connection.agent.request(acp.methods.agent.logout, {})
    }),
    ...(questions === undefined
      ? {}
      : {
          answerQuestion: (sessionId: string, questionId: string, answer: QuestionAnswer) =>
            adapterPromise("answerQuestion", () =>
              questions.answerQuestion(sessionId, questionId, answer)
            )
        }),
    listSessions: adapterPromise("listSessions", async () => {
      const sessions: AgentSessionSummary[] = []
      let cursor: string | undefined
      do {
        const response = await connection.agent.request(
          acp.methods.agent.session.list,
          cursor === undefined ? {} : { cursor }
        )
        sessions.push(
          ...response.sessions.map((session) => ({
            cwd: session.cwd,
            sessionId: session.sessionId,
            ...(session.title == null ? {} : { title: session.title }),
            ...(session.updatedAt == null ? {} : { updatedAt: session.updatedAt })
          }))
        )
        const next = response.nextCursor ?? undefined
        if (next === cursor) break
        cursor = next
      } while (cursor !== undefined)
      return sessions
    }),
    createSession: (cwd, toolGateway) =>
      adapterPromise("createSession", async () => {
        const response = (await connection.agent.request(acp.methods.agent.session.new, {
          cwd,
          mcpServers: mcpServers(toolGateway)
        })) as NewSessionResponse
        if (piStartupInfoBySession !== undefined) {
          const startupInfo = extractPiStartupInfo(response)
          if (startupInfo !== undefined) {
            piStartupInfoBySession.set(response.sessionId, startupInfo)
          }
        }
        nativeConfigIds.set(response.sessionId, acpConfigOptionIds(response))
        const modelState = extractAcpModelState(response)
        if (modelState !== undefined) {
          modelStates.set(response.sessionId, modelState)
        }
        return sessionMetadata(response.sessionId, response, modelState, harnessId)
      }),
    loadSession: (sessionId, cwd, toolGateway) =>
      adapterPromise("loadSession", async () => {
        const response = (await connection.agent.request(acp.methods.agent.session.load, {
          cwd,
          mcpServers: mcpServers(toolGateway),
          sessionId
        })) as AcpSessionMetadataResponse
        nativeConfigIds.set(sessionId, acpConfigOptionIds(response))
        const modelState = extractAcpModelState(response)
        if (modelState !== undefined) {
          modelStates.set(sessionId, modelState)
        }
        return sessionMetadata(sessionId, response, modelState, harnessId)
      }),
    prompt: (sessionId, input) =>
      adapterPromise("prompt", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.prompt, {
          prompt: acpPrompt(normalizePromptInput(input), promptCapabilities),
          sessionId
        })
        const stopDetail = await piSessionError?.(sessionId)
        return {
          stopReason: response.stopReason,
          ...(stopDetail === undefined ? {} : { stopDetail })
        }
      }),
    cancel: (sessionId) =>
      adapterPromise("cancel", async () => {
        // Per spec, cancelling a turn resolves its pending permission
        // requests as cancelled before the agent is notified.
        questions?.cancelQuestions(sessionId)
        await connection.agent.notify(acp.methods.agent.session.cancel, { sessionId })
      }),
    setMode: (sessionId, modeId) =>
      adapterPromise("setMode", async () => {
        await connection.agent.request(acp.methods.agent.session.setMode, { modeId, sessionId })
      }),
    setConfigOption: (sessionId, configId, value) =>
      adapterPromise("setConfigOption", async () => {
        // The model picker is the ACP model-selection extension, applied via
        // `session/set_model`. Grok doesn't implement `session/set_config_option`
        // at all, so routing a model change through it would 404.
        if (usesAcpModelSelectionExtension(configId, nativeConfigIds.get(sessionId))) {
          return applyAcpModelSelection(connection, modelStates, sessionId, value)
        }
        if (configId === acpReasoningEffortConfigId) {
          return applyAcpReasoningEffortSelection(connection, modelStates, sessionId, value)
        }
        const response = await connection.agent.request(acp.methods.agent.session.setConfigOption, {
          configId,
          sessionId,
          value
        })
        return normalizeAcpConfigOptions(response.configOptions ?? [])
      }),
    ...(harnessId !== "grok-build"
      ? {}
      : {
          setGoal: (sessionId: string, update: SetGoalUpdate) =>
            adapterPromise("setGoal", async () => {
              if (update.objective !== undefined) {
                const objective = update.objective.trim()
                if (objective.length === 0) throw new Error("Goal objective cannot be empty")
                if (update.status !== undefined && update.status !== "active") {
                  throw new Error("A new Grok goal must start active")
                }
                if (
                  update.tokenBudget !== undefined &&
                  update.tokenBudget !== null &&
                  (!Number.isSafeInteger(update.tokenBudget) || update.tokenBudget <= 0)
                ) {
                  throw new Error("Goal token budget must be a positive integer")
                }
                await stopGrokGoalTurn(sessionId)
                const now = new Date().toISOString()
                const goal: SessionGoal = {
                  objective,
                  status: "active",
                  tokenBudget: update.tokenBudget ?? null,
                  tokensUsed: 0,
                  timeUsedSeconds: 0,
                  createdAt: now,
                  updatedAt: now
                }
                grokGoals.set(sessionId, goal)
                const budget =
                  update.tokenBudget === undefined || update.tokenBudget === null
                    ? ""
                    : ` --budget ${update.tokenBudget}`
                runGrokGoalPrompt(sessionId, `/goal ${objective}${budget}`, true)
                return goal
              }

              if (update.tokenBudget !== undefined) {
                throw new Error("Grok can only set a token budget when starting a goal")
              }
              if (update.status === "paused") {
                currentGoalOrThrow(sessionId)
                const cancelledActiveTurn = await stopGrokGoalTurn(sessionId)
                if (!cancelledActiveTurn) {
                  await runGrokGoalPrompt(sessionId, "/goal pause")
                }
                const current = currentGoalOrThrow(sessionId)
                const goal = {
                  ...current,
                  status: "paused" as const,
                  updatedAt: new Date().toISOString()
                }
                grokGoals.set(sessionId, goal)
                return goal
              }
              if (update.status === "active") {
                const current = currentGoalOrThrow(sessionId)
                const goal = {
                  ...current,
                  status: "active" as const,
                  updatedAt: new Date().toISOString()
                }
                grokGoals.set(sessionId, goal)
                runGrokGoalPrompt(sessionId, "/goal resume", true)
                return goal
              }
              throw new Error(`Unsupported Grok goal status: ${update.status ?? "unchanged"}`)
            }),
          clearGoal: (sessionId: string) =>
            adapterPromise("clearGoal", async () => {
              await stopGrokGoalTurn(sessionId)
              await runGrokGoalPrompt(sessionId, "/goal clear")
              grokGoals.delete(sessionId)
            })
        }),
    close: runtimeEffect("close", () => {
      connection.close(new Error(stderr()))
      terminate()
    })
  }
}

type AcpPermissionOutcome =
  | { outcome: { outcome: "cancelled" } }
  | { outcome: { optionId: string; outcome: "selected" } }

const createClientApp = (
  onSessionUpdate: (notification: acp.SessionNotification) => void,
  onPermissionRequest: (params: unknown) => Promise<AcpPermissionOutcome>,
  terminals?: AcpTerminalHost,
  grok?: AcpGrokControls
): acp.ClientApp => {
  const app = acp
    .client({ name: "Codevisor" })
    .onNotification(acp.methods.client.session.update, ({ params }) => {
      onSessionUpdate(params)
    })
    // Permission requests are the agent explicitly deferring to the human
    // (ACP's contract — this is what makes plan mode gate anything), so they
    // surface as blocking questions rather than being auto-approved.
    .onRequest(acp.methods.client.session.requestPermission, ({ params }) =>
      onPermissionRequest(params)
    )
  if (grok !== undefined) {
    const planApproval = ({ params }: { readonly params: unknown }) =>
      grok.requestPlanApproval(params)
    const askUserQuestion = ({ params }: { readonly params: unknown }) =>
      grok.askUserQuestion(params)
    for (const method of ["_x.ai/exit_plan_mode", "x.ai/exit_plan_mode"]) {
      app.onRequest<unknown, GrokPlanApprovalResponse>(method, (params) => params, planApproval)
    }
    for (const method of ["_x.ai/ask_user_question", "x.ai/ask_user_question"]) {
      app.onRequest<unknown, GrokAskUserQuestionResponse>(
        method,
        (params) => params,
        askUserQuestion
      )
    }
    for (const method of ["_x.ai/session_notification", "x.ai/session_notification"]) {
      app.onNotification<unknown>(
        method,
        (params) => params,
        ({ params }) => grok.onSessionNotification(params)
      )
    }
  }
  if (terminals === undefined) {
    return app
  }
  // Client-side terminals: the agent runs shell commands in processes we own
  // (see acp-terminals.ts). Only registered when the terminal capability is
  // advertised, so agents without the capability never reach these.
  return app
    .onRequest(acp.methods.client.terminal.create, ({ params }) =>
      terminals.create({
        sessionId: params.sessionId,
        command: params.command,
        ...(params.args === undefined ? {} : { args: params.args }),
        ...(params.env === undefined || params.env === null ? {} : { env: params.env }),
        ...(params.cwd === undefined ? {} : { cwd: params.cwd }),
        ...(params.outputByteLimit === undefined ? {} : { outputByteLimit: params.outputByteLimit })
      })
    )
    .onRequest(acp.methods.client.terminal.output, ({ params }) =>
      terminals.output({ sessionId: params.sessionId, terminalId: params.terminalId })
    )
    .onRequest(acp.methods.client.terminal.waitForExit, ({ params }) =>
      terminals.waitForExit({ sessionId: params.sessionId, terminalId: params.terminalId })
    )
    .onRequest(acp.methods.client.terminal.kill, ({ params }) => {
      terminals.kill({ sessionId: params.sessionId, terminalId: params.terminalId })
      return {}
    })
    .onRequest(acp.methods.client.terminal.release, ({ params }) => {
      terminals.release({ sessionId: params.sessionId, terminalId: params.terminalId })
      return {}
    })
}

/// One `session/request_permission` held open while the human answers.
interface PendingAcpQuestion {
  readonly sessionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly cancelledResponse: unknown
  readonly responseFor: (answer: QuestionAnswer) => unknown
  readonly resolve: (response: unknown) => void
}

/// Pure mapping from a permission request onto the question wire shape.
/// Exported for unit tests — the live wiring runs inside the stdio connector.
/// Returns undefined when the request carries no options (auto-cancel).
export const acpPermissionQuestion = (
  params: unknown
):
  | {
      readonly sessionId: string
      readonly spec: QuestionSpec
      readonly optionIds: ReadonlyMap<string, string>
      readonly planDocument: string | undefined
    }
  | undefined => {
  if (typeof params !== "object" || params === null) return undefined
  const request = params as Record<string, unknown>
  const sessionId = typeof request.sessionId === "string" ? request.sessionId : undefined
  const rawOptions = Array.isArray(request.options) ? request.options : []
  const options = rawOptions.flatMap((option) => {
    if (typeof option !== "object" || option === null) return []
    const entry = option as Record<string, unknown>
    return typeof entry.optionId === "string" && typeof entry.name === "string"
      ? [{ name: entry.name, optionId: entry.optionId }]
      : []
  })
  if (sessionId === undefined || options.length === 0) return undefined
  const toolCall =
    typeof request.toolCall === "object" && request.toolCall !== null
      ? (request.toolCall as Record<string, unknown>)
      : {}
  const title = typeof toolCall.title === "string" ? toolCall.title : undefined
  // Plan-mode exits (claude-agent-acp's "Ready to code?") carry the proposed
  // plan markdown as switch_mode tool-call content — surface it as the
  // Proposed Plan card alongside the question.
  const planDocument =
    toolCall.kind === "switch_mode" ? textFromToolCallContent(toolCall.content) : undefined
  return {
    optionIds: new Map(options.map((option) => [option.name, option.optionId])),
    planDocument,
    sessionId,
    spec: {
      allowsOther: false,
      id: "permission",
      options: options.map((option) => ({ label: option.name })),
      question: title !== undefined && title.length > 0 ? title : "Allow the agent to proceed?"
    }
  }
}

const textFromToolCallContent = (content: unknown): string | undefined => {
  if (!Array.isArray(content)) return undefined
  const text = content
    .flatMap((block) => {
      if (typeof block !== "object" || block === null) return []
      const entry = block as { type?: unknown; content?: { type?: unknown; text?: unknown } }
      return entry.type === "content" &&
        entry.content?.type === "text" &&
        typeof entry.content.text === "string"
        ? [entry.content.text]
        : []
    })
    .join("\n")
    .trim()
  return text.length > 0 ? text : undefined
}

/// Maps the human's answer back onto the ACP permission outcome: the selected
/// option label resolves to its optionId; anything else cancels.
export const acpPermissionOutcome = (
  optionIds: ReadonlyMap<string, string>,
  answer: QuestionAnswer
): AcpPermissionOutcome => {
  if (answer.outcome === "answered") {
    const label = Object.values(answer.answers ?? {}).flatMap((entry) => [...entry.answers])[0]
    const optionId = label === undefined ? undefined : optionIds.get(label)
    if (optionId !== undefined) {
      return { outcome: { optionId, outcome: "selected" } }
    }
  }
  return { outcome: { outcome: "cancelled" } }
}

const GROK_PLAN_QUESTION_ID = "grok_exit_plan_mode"
const GROK_IMPLEMENT_PLAN_LABEL = "Implement plan"
const GROK_KEEP_PLANNING_LABEL = "Keep planning"
const GROK_ABANDON_PLAN_LABEL = "Abandon plan"

interface GrokMappedQuestion<Response> {
  readonly sessionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly planDocument?: string
  readonly cancelledResponse: Response
  readonly responseFor: (answer: QuestionAnswer) => Response
}

const unwrapGrokExtensionParams = (params: unknown): unknown => {
  if (typeof params !== "object" || params === null) return params
  const wrapper = params as Record<string, unknown>
  return typeof wrapper.method === "string" && wrapper.params !== undefined
    ? wrapper.params
    : params
}

const grokGoalStatus = (status: string): GoalStatus | undefined => {
  switch (status) {
    case "active":
      return "active"
    case "user_paused":
    case "back_off_paused":
    case "no_progress_paused":
    case "doom_loop_paused":
      return "paused"
    case "infra_paused":
    case "blocked":
      return "blocked"
    case "budget_limited":
      return "budgetLimited"
    case "complete":
      return "complete"
    default:
      return undefined
  }
}

export interface GrokGoalNotification {
  readonly sessionId: string
  readonly goal: SessionGoal | undefined
  readonly event: RuntimeEvent
}

/// Maps Grok's x.ai goal progress extension onto Codevisor's shared goal
/// snapshot. The lookup preserves createdAt across the many progress ticks.
export const grokGoalNotification = (
  params: unknown,
  currentGoal: (sessionId: string) => SessionGoal | undefined = () => undefined,
  now = new Date().toISOString()
): GrokGoalNotification | undefined => {
  params = unwrapGrokExtensionParams(params)
  if (typeof params !== "object" || params === null) return undefined
  const notification = params as Record<string, unknown>
  if (typeof notification.sessionId !== "string") return undefined
  if (typeof notification.update !== "object" || notification.update === null) return undefined
  const update = notification.update as Record<string, unknown>
  if (update.sessionUpdate !== "goal_updated" || typeof update.status !== "string") {
    return undefined
  }
  if (update.status === "cleared") {
    return {
      sessionId: notification.sessionId,
      goal: undefined,
      event: {
        kind: "session.updated",
        subjectId: notification.sessionId,
        payload: { goalCleared: true }
      }
    }
  }
  const status = grokGoalStatus(update.status)
  if (status === undefined || typeof update.objective !== "string") return undefined
  const previous = currentGoal(notification.sessionId)
  const tokenBudget =
    typeof update.token_budget === "number" && Number.isFinite(update.token_budget)
      ? update.token_budget
      : null
  const tokensUsed =
    typeof update.tokens_used === "number" && Number.isFinite(update.tokens_used)
      ? update.tokens_used
      : 0
  const timeUsedSeconds =
    typeof update.elapsed_ms === "number" && Number.isFinite(update.elapsed_ms)
      ? update.elapsed_ms / 1_000
      : 0
  const goal: SessionGoal = {
    objective: update.objective,
    status,
    ...(update.verifying_completion === true
      ? { activity: "verifying" as const }
      : update.planning === true
        ? { activity: "planning" as const }
        : {}),
    tokenBudget,
    tokensUsed,
    timeUsedSeconds,
    createdAt: previous?.createdAt ?? now,
    updatedAt: now
  }
  return {
    sessionId: notification.sessionId,
    goal,
    event: {
      kind: "session.updated",
      subjectId: notification.sessionId,
      payload: { goal }
    }
  }
}

type GrokPlanApprovalResponse =
  | { readonly outcome: "approved" | "abandoned" }
  | { readonly outcome: "cancelled"; readonly feedback?: string }

export const grokPlanApprovalQuestion = (
  params: unknown
): GrokMappedQuestion<GrokPlanApprovalResponse> | undefined => {
  params = unwrapGrokExtensionParams(params)
  if (typeof params !== "object" || params === null) return undefined
  const request = params as Record<string, unknown>
  if (typeof request.sessionId !== "string") return undefined
  const planDocument = typeof request.planContent === "string" ? request.planContent : undefined
  const questions: ReadonlyArray<QuestionSpec> = [
    {
      id: GROK_PLAN_QUESTION_ID,
      header: "Plan",
      question: "Ready to implement this plan?",
      options: [
        { label: GROK_IMPLEMENT_PLAN_LABEL, description: "Start building" },
        { label: GROK_KEEP_PLANNING_LABEL, description: "Keep refining the plan" },
        { label: GROK_ABANDON_PLAN_LABEL, description: "Exit plan mode without implementing" }
      ],
      allowsOther: true
    }
  ]
  return {
    sessionId: request.sessionId,
    questions,
    ...(planDocument === undefined ? {} : { planDocument }),
    cancelledResponse: { outcome: "cancelled" },
    responseFor: (answer) => {
      if (answer.outcome === "cancelled") return { outcome: "cancelled" }
      const entry = answer.answers?.[GROK_PLAN_QUESTION_ID]
      const selected = entry?.answers[0]
      if (selected === GROK_IMPLEMENT_PLAN_LABEL) return { outcome: "approved" }
      if (selected === GROK_ABANDON_PLAN_LABEL) return { outcome: "abandoned" }
      const note = entry?.note?.trim()
      const freeform =
        selected !== undefined &&
        ![GROK_KEEP_PLANNING_LABEL, GROK_IMPLEMENT_PLAN_LABEL, GROK_ABANDON_PLAN_LABEL].includes(
          selected
        )
          ? selected.trim()
          : ""
      const feedback = note === undefined || note === "" ? freeform : note
      return feedback === "" ? { outcome: "cancelled" } : { outcome: "cancelled", feedback }
    }
  }
}

interface GrokQuestionOption {
  readonly label: string
  readonly description?: string
  readonly preview?: string
}

interface GrokQuestion {
  readonly question: string
  readonly options: ReadonlyArray<GrokQuestionOption>
  readonly multiSelect: boolean
}

type GrokAskUserQuestionResponse =
  | { readonly outcome: "cancelled" }
  | {
      readonly outcome: "accepted"
      readonly answers: Readonly<Record<string, ReadonlyArray<string>>>
      readonly annotations?: Readonly<
        Record<string, { readonly preview?: string; readonly notes?: string }>
      >
    }

const parseGrokQuestions = (value: unknown): ReadonlyArray<GrokQuestion> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    if (typeof entry !== "object" || entry === null) return []
    const question = entry as Record<string, unknown>
    if (typeof question.question !== "string" || !Array.isArray(question.options)) return []
    const options = question.options.flatMap((raw) => {
      if (typeof raw !== "object" || raw === null) return []
      const option = raw as Record<string, unknown>
      if (typeof option.label !== "string") return []
      return [
        {
          label: option.label,
          ...(typeof option.description === "string" ? { description: option.description } : {}),
          ...(typeof option.preview === "string" ? { preview: option.preview } : {})
        }
      ]
    })
    return [
      {
        question: question.question,
        options,
        multiSelect: question.multiSelect === true
      }
    ]
  })
}

export const grokAskUserQuestion = (
  params: unknown
): GrokMappedQuestion<GrokAskUserQuestionResponse> | undefined => {
  params = unwrapGrokExtensionParams(params)
  if (typeof params !== "object" || params === null) return undefined
  const request = params as Record<string, unknown>
  if (typeof request.sessionId !== "string") return undefined
  const grokQuestions = parseGrokQuestions(request.questions)
  if (grokQuestions.length === 0) return undefined
  const questions: ReadonlyArray<QuestionSpec> = grokQuestions.map((question) => ({
    id: question.question,
    question: question.question,
    options: question.options.map((option) => ({
      label: option.label,
      ...(option.description === undefined ? {} : { description: option.description })
    })),
    ...(question.multiSelect ? { multiSelect: true } : {}),
    allowsOther: true
  }))
  return {
    sessionId: request.sessionId,
    questions,
    cancelledResponse: { outcome: "cancelled" },
    responseFor: (answer) => {
      if (answer.outcome === "cancelled") return { outcome: "cancelled" }
      const answers: Record<string, ReadonlyArray<string>> = {}
      const annotations: Record<string, { readonly preview?: string; readonly notes?: string }> = {}
      for (const question of grokQuestions) {
        const entry = answer.answers?.[question.question]
        if (entry === undefined) continue
        const knownLabels = new Set(question.options.map((option) => option.label))
        const unknown = entry.answers.find((selected) => !knownLabels.has(selected))
        const selected = entry.answers.filter((label) => knownLabels.has(label))
        const notes = entry.note?.trim() || unknown?.trim()
        if (selected.length === 0 && (notes === undefined || notes === "")) continue
        answers[question.question] =
          selected.length === 0 && notes !== undefined ? ["Other"] : selected
        const preview =
          question.multiSelect || selected.length !== 1
            ? undefined
            : question.options.find((option) => option.label === selected[0])?.preview
        if (preview !== undefined || (notes !== undefined && notes !== "")) {
          annotations[question.question] = {
            ...(preview === undefined ? {} : { preview }),
            ...(notes === undefined || notes === "" ? {} : { notes })
          }
        }
      }
      return {
        outcome: "accepted",
        answers,
        ...(Object.keys(annotations).length === 0 ? {} : { annotations })
      }
    }
  }
}

export const runtimeEventFromNotification = (
  notification: acp.SessionNotification
): RuntimeEvent => {
  const update = notification.update
  switch (update.sessionUpdate) {
    case "user_message_chunk":
    case "agent_message_chunk":
    case "agent_thought_chunk":
    case "plan":
    case "available_commands_update":
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: update
      }
    case "tool_call":
    case "tool_call_update":
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: withDiffStats(update)
      }
    case "session_info_update":
    case "usage_update":
      return {
        kind: "session.updated",
        subjectId: notification.sessionId,
        payload: update
      }
    default:
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: update
      }
  }
}

/// pi-acp includes Pi's human-readable startup prelude in `_meta` and then
/// republishes that exact text as an agent message. It is useful in terminals,
/// but in a native transcript it looks like the assistant spoke before the
/// user. Keep the exact value so only that adapter-owned message is suppressed.
export const extractPiStartupInfo = (response: unknown): string | undefined => {
  if (typeof response !== "object" || response === null) return undefined
  const meta = (response as { readonly _meta?: unknown })._meta
  if (typeof meta !== "object" || meta === null) return undefined
  const piAcp = (meta as { readonly piAcp?: unknown }).piAcp
  if (typeof piAcp !== "object" || piAcp === null) return undefined
  const startupInfo = (piAcp as { readonly startupInfo?: unknown }).startupInfo
  return typeof startupInfo === "string" && startupInfo.length > 0 ? startupInfo : undefined
}

export const isPiStartupInfoNotification = (
  notification: acp.SessionNotification,
  startupInfo: string
): boolean => {
  const update = notification.update
  return (
    update.sessionUpdate === "agent_message_chunk" &&
    update.content.type === "text" &&
    update.content.text === startupInfo
  )
}

export const piAssistantErrorFromSessionJsonl = (contents: string): string | undefined => {
  const lines = contents.split("\n")
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index]?.trim()
    if (!line) continue
    try {
      const entry = JSON.parse(line) as {
        readonly type?: unknown
        readonly message?: {
          readonly role?: unknown
          readonly stopReason?: unknown
          readonly errorMessage?: unknown
        }
      }
      if (entry.type !== "message") continue
      if (entry.message?.role !== "assistant" || entry.message.stopReason !== "error") {
        return undefined
      }
      if (typeof entry.message.errorMessage !== "string") return undefined
      return humanReadablePiError(entry.message.errorMessage)
    } catch {
      return undefined
    }
  }
  return undefined
}

const humanReadablePiError = (message: string): string => {
  const jsonStart = message.indexOf("{")
  if (jsonStart >= 0) {
    try {
      const parsed = JSON.parse(message.slice(jsonStart)) as {
        readonly error?: { readonly message?: unknown }
      }
      if (typeof parsed.error?.message === "string" && parsed.error.message.trim().length > 0) {
        return parsed.error.message.trim()
      }
    } catch {
      // Keep the provider's original text when it is not JSON-shaped.
    }
  }
  return message.trim()
}

const readPiSessionError = async (
  sessionId: string,
  homeDirectory: string
): Promise<string | undefined> => {
  try {
    const mapContents = await readFile(
      join(homeDirectory, ".pi", "pi-acp", "session-map.json"),
      "utf8"
    )
    const map = JSON.parse(mapContents) as {
      readonly sessions?: Record<string, { readonly sessionFile?: unknown }>
    }
    const sessionFile = map.sessions?.[sessionId]?.sessionFile
    if (typeof sessionFile !== "string" || sessionFile.length === 0) return undefined
    return piAssistantErrorFromSessionJsonl(await readFile(sessionFile, "utf8"))
  } catch {
    // Recovery is best-effort until pi-acp forwards message_end errors itself.
    return undefined
  }
}

/// ACP adapters deliver diffs only at completion; attach the added/removed
/// line counts so clients can render the +N/−N header without re-diffing.
const withDiffStats = (update: { readonly content?: unknown }): Record<string, unknown> => {
  const content = update.content
  if (!Array.isArray(content)) {
    return update as Record<string, unknown>
  }
  const stats: Array<DiffStat> = []
  for (const block of content) {
    if (
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "diff"
    ) {
      const diff = block as { path?: unknown; oldText?: unknown; newText?: unknown }
      if (typeof diff.path === "string" && typeof diff.newText === "string") {
        stats.push(
          diffStatsFromTexts(
            diff.path,
            typeof diff.oldText === "string" ? diff.oldText : undefined,
            diff.newText
          )
        )
      }
    }
  }
  return stats.length === 0
    ? (update as Record<string, unknown>)
    : { ...(update as Record<string, unknown>), diffStats: stats }
}

const captureStderr = (child: ChildProcessWithoutNullStreams): (() => string) => {
  let buffer = ""
  child.stderr.setEncoding("utf8")
  child.stderr.on("data", (chunk: string) => {
    buffer = `${buffer}${chunk}`.slice(-8192)
  })
  return () => buffer
}
/* v8 ignore stop */

/// The synthesized config-option id for the ACP model-selection extension.
/// Agents that report `session/new.models` (e.g. grok) expose their model list
/// via this optional extension rather than a `configOptions` entry, and apply a
/// change through `session/set_model` — NOT `session/set_config_option` (which
/// grok doesn't implement at all). `setConfigOption` routes this id accordingly.
export const acpModelConfigId = "model"
export const acpReasoningEffortConfigId = "reasoning_effort"

interface AcpReasoningEffortOption {
  readonly id: string
  readonly value: string
  readonly name: string
  readonly description?: string
  readonly isDefault: boolean
}

interface AcpReasoningEffortState {
  readonly options: ReadonlyArray<AcpReasoningEffortOption>
  readonly currentOptionId: string
}

interface AcpModelInfo {
  readonly modelId: string
  readonly name: string
  readonly description?: string
  readonly reasoning?: AcpReasoningEffortState
}

interface AcpModelState {
  readonly currentModelId: string
  readonly availableModels: ReadonlyArray<AcpModelInfo>
}

const canonicalReasoningEffort = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined
  const normalized = value.toLowerCase()
  if (normalized === "max") return "xhigh"
  return ["none", "minimal", "low", "medium", "high", "xhigh"].includes(normalized)
    ? normalized
    : undefined
}

const reasoningEffortName = (value: string): string => {
  switch (value) {
    case "xhigh":
      return "X-High"
    default:
      return `${value.slice(0, 1).toUpperCase()}${value.slice(1)}`
  }
}

const reasoningEffortDisplayName = (label: unknown, value: string): string => {
  if (typeof label !== "string" || label === "") return reasoningEffortName(value)
  const concise = label.replace(/\s+effort$/i, "").trim()
  return concise === "" ? label : concise
}

const legacyReasoningEfforts = (): ReadonlyArray<AcpReasoningEffortOption> =>
  ["minimal", "low", "medium", "high", "xhigh"].map((value) => ({
    id: value,
    value,
    name: reasoningEffortName(value),
    isDefault: false
  }))

const parseReasoningEffortOptions = (
  meta: Readonly<Record<string, unknown>>
): ReadonlyArray<AcpReasoningEffortOption> => {
  if (meta.supportsReasoningEffort !== true) return []
  const raw = meta.reasoningEfforts
  if (!Array.isArray(raw)) return legacyReasoningEfforts()
  const parsed = raw.flatMap((entry) => {
    if (typeof entry === "string") {
      const value = canonicalReasoningEffort(entry)
      return value === undefined
        ? []
        : [{ id: value, value, name: reasoningEffortName(value), isDefault: false }]
    }
    if (typeof entry !== "object" || entry === null) return []
    const option = entry as Record<string, unknown>
    const value = canonicalReasoningEffort(option.value)
    if (value === undefined) return []
    return [
      {
        id: typeof option.id === "string" && option.id !== "" ? option.id : value,
        value,
        name: reasoningEffortDisplayName(option.label, value),
        ...(typeof option.description === "string" ? { description: option.description } : {}),
        isDefault: option.default === true
      }
    ]
  })
  return parsed.length === 0 ? legacyReasoningEfforts() : parsed
}

const selectedGrokReasoningOptionId = (response: unknown): string | undefined => {
  if (typeof response !== "object" || response === null) return undefined
  const meta = (response as { readonly _meta?: unknown })._meta
  if (typeof meta !== "object" || meta === null) return undefined
  const sessionConfig = (meta as Record<string, unknown>)["x.ai/sessionConfig"]
  if (typeof sessionConfig !== "object" || sessionConfig === null) return undefined
  const options = (sessionConfig as Record<string, unknown>).options
  if (!Array.isArray(options)) return undefined
  const selected = options.find(
    (entry) =>
      typeof entry === "object" &&
      entry !== null &&
      (entry as Record<string, unknown>).category === "mode" &&
      (entry as Record<string, unknown>).selected === true
  ) as Record<string, unknown> | undefined
  return typeof selected?.id === "string" ? selected.id : undefined
}

const reasoningStateFromMeta = (
  meta: Readonly<Record<string, unknown>> | undefined,
  selectedOptionId?: string
): AcpReasoningEffortState | undefined => {
  if (meta === undefined) return undefined
  const options = parseReasoningEffortOptions(meta)
  if (options.length === 0) return undefined
  const currentEffort = canonicalReasoningEffort(meta.reasoningEffort)
  const currentOption =
    options.find((option) => option.id === selectedOptionId) ??
    options.find((option) => option.value === currentEffort) ??
    options.find((option) => option.isDefault) ??
    options[0]
  return currentOption === undefined ? undefined : { currentOptionId: currentOption.id, options }
}

/// Reads the optional ACP model-selection extension off a `session/new` (or
/// `session/load`) response. The field is not part of the SDK's typed schema,
/// so it arrives untyped — the SDK forwards the raw JSON-RPC result unparsed —
/// hence the defensive shape checks. Returns undefined when absent or malformed
/// so agents without the extension are left untouched (no empty picker).
export const extractAcpModelState = (response: unknown): AcpModelState | undefined => {
  if (typeof response !== "object" || response === null) {
    return undefined
  }
  const models = (response as { readonly models?: unknown }).models
  if (typeof models !== "object" || models === null) {
    return undefined
  }
  const currentModelId = (models as { readonly currentModelId?: unknown }).currentModelId
  const rawAvailable = (models as { readonly availableModels?: unknown }).availableModels
  if (typeof currentModelId !== "string" || !Array.isArray(rawAvailable)) {
    return undefined
  }
  const selectedReasoningOptionId = selectedGrokReasoningOptionId(response)
  const availableModels = rawAvailable.flatMap((entry) => {
    if (typeof entry !== "object" || entry === null) {
      return []
    }
    const model = entry as {
      readonly modelId?: unknown
      readonly name?: unknown
      readonly description?: unknown
      readonly _meta?: unknown
      readonly meta?: unknown
    }
    if (typeof model.modelId !== "string") {
      return []
    }
    const rawMeta = model._meta ?? model.meta
    const meta =
      typeof rawMeta === "object" && rawMeta !== null
        ? (rawMeta as Readonly<Record<string, unknown>>)
        : undefined
    const reasoning = reasoningStateFromMeta(
      meta,
      model.modelId === currentModelId ? selectedReasoningOptionId : undefined
    )
    return [
      {
        modelId: model.modelId,
        name: typeof model.name === "string" ? model.name : model.modelId,
        ...(typeof model.description === "string" ? { description: model.description } : {}),
        ...(reasoning === undefined ? {} : { reasoning })
      }
    ]
  })
  if (availableModels.length === 0) {
    return undefined
  }
  return { availableModels, currentModelId }
}

export const acpConfigOptionIds = (response: unknown): ReadonlySet<string> => {
  if (typeof response !== "object" || response === null) return new Set()
  const options = (response as { readonly configOptions?: unknown }).configOptions
  if (!Array.isArray(options)) return new Set()
  return new Set(
    options.flatMap((option) => {
      if (typeof option !== "object" || option === null) return []
      const id = (option as { readonly id?: unknown }).id
      return typeof id === "string" ? [id] : []
    })
  )
}

export const usesAcpModelSelectionExtension = (
  configId: string,
  nativeConfigIds: ReadonlySet<string> | undefined
): boolean => configId === acpModelConfigId && !nativeConfigIds?.has(acpModelConfigId)

/// Synthesizes the Codevisor `category: "model"` picker option from the ACP model
/// extension so clients render a model chip — mirroring the shape claude/codex
/// build for their native model pickers.
export const acpModelConfigOption = (state: AcpModelState): SessionConfigOption => ({
  category: "model",
  currentValue: state.currentModelId,
  id: acpModelConfigId,
  name: "Model",
  options: state.availableModels.map((model) => ({
    value: model.modelId,
    name: model.name,
    ...(model.description === undefined ? {} : { description: model.description })
  }))
})

export const acpReasoningEffortConfigOption = (
  state: AcpModelState
): SessionConfigOption | undefined => {
  const current = state.availableModels.find((model) => model.modelId === state.currentModelId)
  const reasoning = current?.reasoning
  if (reasoning === undefined) return undefined
  return {
    category: "thought_level",
    currentValue: reasoning.currentOptionId,
    id: acpReasoningEffortConfigId,
    name: "Reasoning",
    options: reasoning.options.map((option) => ({
      value: option.id,
      name: option.name,
      ...(option.description === undefined ? {} : { description: option.description })
    }))
  }
}

const acpModelConfigOptions = (state: AcpModelState): ReadonlyArray<SessionConfigOption> => {
  const reasoning = acpReasoningEffortConfigOption(state)
  return reasoning === undefined
    ? [acpModelConfigOption(state)]
    : [acpModelConfigOption(state), reasoning]
}

/// `session/set_model` answers with a Rust-style `Result` under `_meta.model`
/// (`{ Ok: modelId }` on success, `{ Err }` on failure).
interface AcpSetModelResult {
  readonly _meta?: {
    readonly model?: { readonly Ok?: unknown; readonly Err?: unknown }
  }
}

/// Applies a model choice via the ACP model-selection setter and returns the
/// refreshed config options to broadcast. An `Err` result throws so the client
/// surfaces the failure instead of silently keeping the wrong model. Resumed
/// sessions may have no cached model list (load didn't report one) — fall back
/// to a single-entry option for the confirmed model so the chip still tracks it.
export const applyAcpModelSelection = async (
  connection: acp.ClientConnection,
  modelStates: Map<string, AcpModelState>,
  sessionId: string,
  modelId: string
): Promise<ReadonlyArray<SessionConfigOption>> => {
  const result = (await connection.agent.request("session/set_model", {
    modelId,
    sessionId
  })) as AcpSetModelResult
  const outcome = result?._meta?.model
  if (outcome?.Err !== undefined) {
    const detail = typeof outcome.Err === "string" ? outcome.Err : JSON.stringify(outcome.Err)
    throw new Error(`session/set_model failed: ${detail}`)
  }
  const currentModelId = typeof outcome?.Ok === "string" ? outcome.Ok : modelId
  const existing = modelStates.get(sessionId)
  const state: AcpModelState = {
    availableModels:
      existing === undefined
        ? [{ modelId: currentModelId, name: currentModelId }]
        : existing.availableModels,
    currentModelId
  }
  modelStates.set(sessionId, state)
  return acpModelConfigOptions(state)
}

/// Grok applies a per-session effort by setting the current model again with
/// `_meta.reasoningEffort`. The picker value is the server-defined option id;
/// the request carries its canonical value so custom ids such as `deep` map to
/// the xAI wire value (`xhigh`) correctly.
export const applyAcpReasoningEffortSelection = async (
  connection: acp.ClientConnection,
  modelStates: Map<string, AcpModelState>,
  sessionId: string,
  optionId: string
): Promise<ReadonlyArray<SessionConfigOption>> => {
  const existing = modelStates.get(sessionId)
  const current = existing?.availableModels.find(
    (model) => model.modelId === existing.currentModelId
  )
  const selected = current?.reasoning?.options.find((option) => option.id === optionId)
  if (existing === undefined || current === undefined || selected === undefined) {
    throw new Error(`Unknown reasoning effort option: ${optionId}`)
  }
  const result = (await connection.agent.request("session/set_model", {
    _meta: { reasoningEffort: selected.value },
    modelId: existing.currentModelId,
    sessionId
  })) as AcpSetModelResult
  const outcome = result?._meta?.model
  if (outcome?.Err !== undefined) {
    const detail = typeof outcome.Err === "string" ? outcome.Err : JSON.stringify(outcome.Err)
    throw new Error(`session/set_model failed: ${detail}`)
  }
  const reasoning: AcpReasoningEffortState = {
    currentOptionId: selected.id,
    options: current.reasoning!.options
  }
  const state: AcpModelState = {
    currentModelId: existing.currentModelId,
    availableModels: existing.availableModels.map((model) =>
      model.modelId === existing.currentModelId ? { ...model, reasoning } : model
    )
  }
  modelStates.set(sessionId, state)
  return acpModelConfigOptions(state)
}

/// Grok implements `session/set_mode` for these ids but currently omits the
/// standard ACP `modes` field from session/new and session/load responses.
/// Advertising the known modes lets Codevisor's existing plan toggle drive
/// the upstream plan-mode state machine.
export const grokModeState: SessionModeState = {
  currentModeId: "default",
  availableModes: [
    {
      id: "default",
      name: "Build",
      description: "Work normally with the configured permissions.",
      canonicalId: "fullAccess"
    },
    {
      id: "plan",
      name: "Plan",
      description: "Explore and propose a plan before implementation.",
      canonicalId: "plan"
    },
    {
      id: "ask",
      name: "Ask",
      description: "Answer questions without making changes.",
      canonicalId: "ask"
    }
  ]
}

interface AcpSessionMetadataResponse {
  readonly configOptions?: ReadonlyArray<AcpSessionConfigOption> | null
  readonly modes?: AcpSessionModeState | null
}

const sessionMetadata = (
  sessionId: string,
  response: AcpSessionMetadataResponse,
  modelState: AcpModelState | undefined,
  harnessId?: string
): AgentSessionMetadata => {
  const configOptions = normalizeAcpConfigOptions(response.configOptions ?? [])
  // Append each synthesized picker unless the adapter already reported an
  // equivalent native option — don't double up.
  const withModel = [...configOptions]
  if (modelState !== undefined) {
    if (!withModel.some((option) => option.category === "model")) {
      withModel.push(acpModelConfigOption(modelState))
    }
    const reasoning = acpReasoningEffortConfigOption(modelState)
    if (
      reasoning !== undefined &&
      !withModel.some((option) => option.id === acpReasoningEffortConfigId)
    ) {
      withModel.push(reasoning)
    }
  }
  const modes =
    response.modes === undefined || response.modes === null
      ? harnessId === "grok-build"
        ? grokModeState
        : undefined
      : normalizeModeState(response.modes)
  return {
    sessionId,
    ...(modes === undefined ? {} : { modes }),
    ...(harnessId === "grok-build" ? { supportsGoals: true } : {}),
    configOptions: withModel
  }
}

/// Best-effort mapping from agent-defined ACP mode ids/names onto Codevisor's
/// canonical vocabulary. Order matters: the first matching pattern wins.
/// Unmapped modes stay native-only and render in the picker's overflow section.
const CANONICAL_MODE_PATTERNS: ReadonlyArray<{
  readonly canonicalId: CanonicalModeId
  readonly pattern: RegExp
}> = [
  { canonicalId: "plan", pattern: /^plan/i },
  { canonicalId: "readOnly", pattern: /read[-_ ]?only/i },
  { canonicalId: "autoEdit", pattern: /accept[-_ ]?edits|auto[-_ ]?edit/i },
  { canonicalId: "fullAccess", pattern: /bypass|full[-_ ]?access|yolo/i },
  { canonicalId: "ask", pattern: /^(default|ask|normal)$/i }
]

const canonicalModeIdFor = (mode: AcpSessionMode): CanonicalModeId | undefined =>
  CANONICAL_MODE_PATTERNS.find(
    (entry) => entry.pattern.test(mode.id) || entry.pattern.test(mode.name)
  )?.canonicalId

export const normalizeModeState = (state: AcpSessionModeState): SessionModeState => ({
  currentModeId: state.currentModeId,
  availableModes: state.availableModes.map((mode) => {
    const canonicalId = canonicalModeIdFor(mode)
    return {
      id: mode.id,
      name: mode.name,
      ...(mode.description === undefined || mode.description === null
        ? {}
        : { description: mode.description }),
      ...(canonicalId === undefined ? {} : { canonicalId })
    }
  })
})

export const normalizeAcpConfigOptions = (
  options: ReadonlyArray<AcpSessionConfigOption>
): ReadonlyArray<SessionConfigOption> =>
  options.flatMap((option) => {
    if (option.type !== "select" || typeof option.currentValue !== "string") {
      return []
    }
    return [
      {
        id: option.id,
        name: option.name,
        ...(option.description === undefined || option.description === null
          ? {}
          : { description: option.description }),
        ...(option.category === undefined || option.category === null
          ? {}
          : { category: option.category }),
        currentValue: option.currentValue,
        options: normalizeSelectOptions(option.options, option.category)
      }
    ]
  })

const normalizeSelectOptions = (
  options: ReadonlyArray<AcpSessionConfigSelectOption> | ReadonlyArray<AcpSessionConfigSelectGroup>,
  category: string | null | undefined
): ReadonlyArray<SessionConfigSelectOption> | ReadonlyArray<SessionConfigSelectGroup> => {
  const first = options[0]
  if (first !== undefined && "group" in first) {
    return (options as ReadonlyArray<AcpSessionConfigSelectGroup>).map((group) => ({
      group: group.group,
      name: group.name,
      options: group.options.map((option) => normalizeSelectOption(option, category))
    }))
  }
  return (options as ReadonlyArray<AcpSessionConfigSelectOption>).map((option) =>
    normalizeSelectOption(option, category)
  )
}

const normalizeSelectOption = (
  option: AcpSessionConfigSelectOption,
  category: string | null | undefined
): SessionConfigSelectOption => ({
  value: option.value,
  name:
    category === "thought_level"
      ? option.name.replace(/^(?:Thinking|Reasoning):\s*/i, "")
      : option.name,
  ...(option.description === undefined || option.description === null
    ? {}
    : { description: option.description })
})
