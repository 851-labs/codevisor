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
  Harness,
  QuestionSpec,
  SessionConfigOption,
  SessionConfigSelectGroup,
  SessionConfigSelectOption,
  SessionModeState
} from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { spawn } from "node:child_process"
import type { ChildProcessWithoutNullStreams } from "node:child_process"
import { Readable, Writable } from "node:stream"
import { pathToFileURL } from "node:url"
import { Effect } from "effect"
import type { BackgroundTerminalIntegration } from "../background-terminals.js"
import { diffStatsFromTexts } from "../diff-stats.js"
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
  readonly createSession: (
    cwd: string,
    toolGateway?: ToolGatewayConfig
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly loadSession: (
    sessionId: string,
    cwd: string,
    toolGateway?: ToolGatewayConfig
  ) => Effect.Effect<string, AgentRuntimeError>
  readonly prompt: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<{ readonly stopReason: string }, AgentRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  /// Returns the agent's updated config options (raw ACP shape) so the caller
  /// can broadcast them.
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<unknown, AgentRuntimeError>
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
          emit(turnLifecycleEvent(sessionId, turnId, "ended", result.stopReason))
        )
        return result
      }),
    cancel: connection.cancel(sessionId),
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
        const sessionId = yield* connection.loadSession(agentSessionId, cwd, toolGateway)
        return { handle: handleFor(connection, sessionId, emit), sessionId }
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

const turnLifecycleEvent = (
  sessionId: string,
  turnId: string,
  turnState: "started" | "ended",
  stopReason?: string
): RuntimeEvent => ({
  kind: "session.updated",
  subjectId: sessionId,
  payload: {
    initiatedBy: "user",
    turnId,
    turnState,
    ...(stopReason === undefined ? {} : { stopReason })
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
        // npx/npm launch the actual agent as a descendant. A separate process
        // group lets close/timeout reliably terminate the whole ACP tree.
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
      const safeEmit = (event: RuntimeEvent): void => {
        void emit(event).catch(() => undefined)
      }
      const terminals =
        backgroundTerminals === undefined
          ? undefined
          : makeAcpTerminalHost({
              emit,
              env: request.env,
              integration: backgroundTerminals
            })
      const connection = createClientApp(
        (notification) => {
          safeEmit(runtimeEventFromNotification(notification))
        },
        (params) => {
          const question = acpPermissionQuestion(params)
          if (question === undefined) {
            return Promise.resolve({ outcome: { outcome: "cancelled" as const } })
          }
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
              questions: [question.spec],
              sessionUpdate: "question"
            },
            subjectId: question.sessionId
          })
          return new Promise<AcpPermissionOutcome>((resolve) => {
            pendingQuestions.set(questionId, {
              optionIds: question.optionIds,
              questions: [question.spec],
              resolve,
              sessionId: question.sessionId
            })
          })
        },
        terminals
      ).connect(
        acp.ndJsonStream(
          Writable.toWeb(child.stdin) as WritableStream<Uint8Array>,
          Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>
        )
      )
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
        const outcome = acpPermissionOutcome(pending.optionIds, answer)
        pending.resolve(outcome)
        emitQuestionResolved(
          questionId,
          pending,
          outcome.outcome.outcome === "selected" ? "answered" : "cancelled",
          answer.outcome === "answered" ? answer.answers : undefined
        )
      }
      /// ACP spec: a cancelled turn (and a closing connection) must resolve
      /// pending permission requests as cancelled.
      const cancelQuestions = (sessionId: string | undefined): void => {
        for (const [questionId, pending] of pendingQuestions) {
          if (sessionId !== undefined && pending.sessionId !== sessionId) continue
          pendingQuestions.delete(questionId)
          pending.resolve({ outcome: { outcome: "cancelled" } })
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
        }
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
  auth: AcpAuthControls = { methods: [], canLogout: false }
): AcpAgentConnection => {
  connection.closed.catch(() => undefined)

  // Per-session model list from the ACP model-selection extension, cached so a
  // later `session/set_model` can rebuild the picker with the new current value.
  const modelStates = new Map<string, AcpModelState>()

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
    createSession: (cwd, toolGateway) =>
      adapterPromise("createSession", async () => {
        const response = (await connection.agent.request(acp.methods.agent.session.new, {
          cwd,
          mcpServers: mcpServers(toolGateway)
        })) as NewSessionResponse
        const modelState = extractAcpModelState(response)
        if (modelState !== undefined) {
          modelStates.set(response.sessionId, modelState)
        }
        return sessionMetadata(response, modelState)
      }),
    loadSession: (sessionId, cwd, toolGateway) =>
      adapterPromise("loadSession", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.load, {
          cwd,
          mcpServers: mcpServers(toolGateway),
          sessionId
        })
        const modelState = extractAcpModelState(response)
        if (modelState !== undefined) {
          modelStates.set(sessionId, modelState)
        }
        return sessionId
      }),
    prompt: (sessionId, input) =>
      adapterPromise("prompt", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.prompt, {
          prompt: acpPrompt(normalizePromptInput(input), promptCapabilities),
          sessionId
        })
        return { stopReason: response.stopReason }
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
        if (configId === acpModelConfigId) {
          return applyAcpModelSelection(connection, modelStates, sessionId, value)
        }
        const response = await connection.agent.request(acp.methods.agent.session.setConfigOption, {
          configId,
          sessionId,
          value
        })
        return response.configOptions
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
  terminals?: AcpTerminalHost
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
  /// option label (name) → ACP optionId, for mapping the answer back.
  readonly optionIds: ReadonlyMap<string, string>
  readonly resolve: (outcome: AcpPermissionOutcome) => void
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

interface AcpModelInfo {
  readonly modelId: string
  readonly name: string
  readonly description?: string
}

interface AcpModelState {
  readonly currentModelId: string
  readonly availableModels: ReadonlyArray<AcpModelInfo>
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
  const availableModels = rawAvailable.flatMap((entry) => {
    if (typeof entry !== "object" || entry === null) {
      return []
    }
    const model = entry as {
      readonly modelId?: unknown
      readonly name?: unknown
      readonly description?: unknown
    }
    if (typeof model.modelId !== "string") {
      return []
    }
    return [
      {
        modelId: model.modelId,
        name: typeof model.name === "string" ? model.name : model.modelId,
        ...(typeof model.description === "string" ? { description: model.description } : {})
      }
    ]
  })
  if (availableModels.length === 0) {
    return undefined
  }
  return { availableModels, currentModelId }
}

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
  return [acpModelConfigOption(state)]
}

const sessionMetadata = (
  response: NewSessionResponse,
  modelState: AcpModelState | undefined
): AgentSessionMetadata => {
  const configOptions = normalizeConfigOptions(response.configOptions ?? [])
  // Append the synthesized model picker unless the adapter already reported a
  // native `category: "model"` option — don't double up.
  const withModel =
    modelState !== undefined && !configOptions.some((option) => option.category === "model")
      ? [...configOptions, acpModelConfigOption(modelState)]
      : configOptions
  return {
    sessionId: response.sessionId,
    ...(response.modes === undefined || response.modes === null
      ? {}
      : { modes: normalizeModeState(response.modes) }),
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

const normalizeConfigOptions = (
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
        options: normalizeSelectOptions(option.options)
      }
    ]
  })

const normalizeSelectOptions = (
  options: ReadonlyArray<AcpSessionConfigSelectOption> | ReadonlyArray<AcpSessionConfigSelectGroup>
): ReadonlyArray<SessionConfigSelectOption> | ReadonlyArray<SessionConfigSelectGroup> => {
  const first = options[0]
  if (first !== undefined && "group" in first) {
    return (options as ReadonlyArray<AcpSessionConfigSelectGroup>).map((group) => ({
      group: group.group,
      name: group.name,
      options: group.options.map(normalizeSelectOption)
    }))
  }
  return (options as ReadonlyArray<AcpSessionConfigSelectOption>).map(normalizeSelectOption)
}

const normalizeSelectOption = (
  option: AcpSessionConfigSelectOption
): SessionConfigSelectOption => ({
  value: option.value,
  name: option.name,
  ...(option.description === undefined || option.description === null
    ? {}
    : { description: option.description })
})
