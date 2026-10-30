import {
  sanitizeModelValue,
  type CreateSessionOptions,
  type HarnessAccountContext,
  type HarnessDefinition,
  type InterruptedTurnResume,
  type ProviderEnvironment,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"

import { codexInput } from "./attachments.js"
import type { CodexClient } from "./client.js"
import { isRecord } from "./internal.js"
import { codexModelsFrom } from "./model-list.js"
import { currentCodexModelFor, DEFAULT_CODEX_MODE } from "./models.js"
import { handleNotification } from "./notifications.js"
import { cancelPendingQuestions, serverRequestResponse } from "./questions.js"
import type { CodexSession } from "./session.js"
import { refreshCodexSkills } from "./skills.js"
import { codexThreadConfig } from "./thread-config.js"
import { CodexTitleGenerator } from "./title-generation.js"
import { startCodexTurn } from "./turn-start.js"

export interface CodexStartSessionDeps {
  readonly connect: (
    definition: HarnessDefinition,
    cwd: string,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig,
    disabledFeatures?: ReadonlyArray<string>
  ) => Promise<CodexClient>
  readonly environment: ProviderEnvironment
  readonly readConfigFile: (path: string) => string | undefined
}

const disabledFeaturesFor = (
  sessionOptions: CreateSessionOptions | undefined
): ReadonlyArray<string> => (sessionOptions?.bot === true ? ["goals"] : [])

export const makeStartSession = ({
  connect,
  environment,
  readConfigFile
}: CodexStartSessionDeps) => {
  const startSession = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    resumeThreadId: string | undefined,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig,
    sessionOptions?: CreateSessionOptions
  ): Promise<CodexSession> => {
    const client = await connect(
      definition,
      cwd,
      account,
      toolGateway,
      disabledFeaturesFor(sessionOptions)
    )
    const config = codexThreadConfig({ environment, readConfigFile, account, toolGateway })
    const opened = { resumeThreadId, forkFrom: sessionOptions?.forkFrom }
    const response: unknown = await openThread(client, cwd, opened, config)

    const threadId = threadIdFrom(response)
    if (threadId === undefined) {
      client.close()
      throw new Error("codex app-server did not return a thread id")
    }

    const session = newCodexSession({ client, cwd, emit, resumeThreadId, response, threadId })
    try {
      const modelList = await client.request("model/list", {})
      session.models = codexModelsFrom(modelList)
      adoptDefaultEffort(session)
    } catch {
      session.models = []
    }
    await refreshCodexSkills(session, false)

    attachToClient(session, resumeThreadId !== undefined || opened.forkFrom !== undefined)
    if (resumeThreadId !== undefined && sessionOptions?.resumeInterruptedTurn !== undefined) {
      resumeInterruptedTurn(session, sessionOptions.resumeInterruptedTurn)
    }
    return session
  }
  return startSession
}

const resumeInterruptedTurn = (session: CodexSession, resume: InterruptedTurnResume): void => {
  const input = resume.stoppedTasks.length === 0 ? [] : codexInput({ text: resume.notice })
  void startCodexTurn(session, input).catch(() => undefined)
}

interface OpenedThread {
  readonly client: CodexClient
  readonly cwd: string
  readonly emit: RuntimeEmit
  readonly resumeThreadId: string | undefined
  readonly response: unknown
  readonly threadId: string
}

interface ThreadSource {
  readonly resumeThreadId: string | undefined
  readonly forkFrom: string | undefined
}

const openThread = (
  client: CodexClient,
  cwd: string,
  source: ThreadSource,
  config: Record<string, unknown>
): Promise<unknown> => {
  if (source.forkFrom !== undefined) {
    return client.request("thread/fork", {
      cwd,
      threadId: source.forkFrom,
      config,
      excludeTurns: true,
      deferGoalContinuation: true
    })
  }
  if (source.resumeThreadId === undefined) return client.request("thread/start", { cwd, config })

  return client.request("thread/resume", { cwd, threadId: source.resumeThreadId, config })
}

const threadIdFrom = (response: unknown): string | undefined =>
  isRecord(response) && isRecord(response.thread) && typeof response.thread.id === "string"
    ? response.thread.id
    : undefined

const newCodexSession = (thread: OpenedThread): CodexSession => ({
  activeTurnId: undefined,
  asyncQuestion: undefined,
  heldTurnId: undefined,
  latestContext: undefined,
  latestUsageLimits: undefined,
  client: thread.client,
  collabRunTurns: new Map(),
  collabThreads: new Map(),
  collaborationEngaged: false,
  currentEffort: undefined,
  currentModeId: DEFAULT_CODEX_MODE,
  currentModel: sanitizeModelValue(threadModel(thread.response)),
  currentSpeed: undefined,
  cwd: thread.cwd,
  emit: thread.emit,
  interruptRequested: false,
  pausedForRestart: false,
  itemKinds: new Map(),
  itemTitles: new Map(),
  key: thread.resumeThreadId ?? thread.threadId,
  lastHarnessTitle: undefined,
  lastEmittedGoal: undefined,
  lastGoalEmitAtMs: 0,
  messagePhases: new Map(),
  models: [],
  skills: undefined,
  pendingGoalSnapshot: undefined,
  pendingPrompt: undefined,
  pendingTurnError: undefined,
  pendingQuestions: new Map(),
  threadId: thread.threadId
})

const threadModel = (response: unknown): string =>
  isRecord(response) && typeof response.model === "string" ? response.model : ""

const adoptDefaultEffort = (session: CodexSession): void => {
  const current = currentCodexModelFor(session)
  if (current === undefined) return
  if (session.currentEffort !== undefined) return

  session.currentEffort = current.defaultEffort
}

const attachToClient = (session: CodexSession, resumed: boolean): void => {
  const { client } = session
  client.onNotification((method, params) => {
    handleNotification(session, method, params)
  })
  session.titleGenerator = new CodexTitleGenerator(client, session.threadId, session.cwd, resumed)
  client.onRequest((method, params, signal) =>
    serverRequestResponse(session, method, params, signal)
  )
  client.onClose((error) => {
    handleClientClosed(session, error)
  })
}

const handleClientClosed = (session: CodexSession, error: Error): void => {
  session.titleGenerator?.close()
  if (session.pausedForRestart) return
  session.pendingPrompt?.resolve({ stopReason: "cancelled" })
  session.pendingPrompt = undefined
  cancelPendingQuestions(session)
  void session.emit({
    kind: "session.error",
    payload: { message: error.message },
    subjectId: session.key
  })
}
