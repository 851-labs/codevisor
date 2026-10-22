import {
  sanitizeModelValue,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"

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

export interface CodexStartSessionDeps {
  readonly connect: (
    definition: HarnessDefinition,
    cwd: string,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ) => Promise<CodexClient>
  readonly environment: ProviderEnvironment
  readonly readConfigFile: (path: string) => string | undefined
}

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
    toolGateway?: ToolGatewayConfig
  ): Promise<CodexSession> => {
    const client = await connect(definition, cwd, account, toolGateway)
    const config = codexThreadConfig({ environment, readConfigFile, account, toolGateway })
    const response: unknown = await openThread(client, cwd, resumeThreadId, config)

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

    attachToClient(session, resumeThreadId !== undefined)
    return session
  }
  return startSession
}

interface OpenedThread {
  readonly client: CodexClient
  readonly cwd: string
  readonly emit: RuntimeEmit
  readonly resumeThreadId: string | undefined
  readonly response: unknown
  readonly threadId: string
}

const openThread = (
  client: CodexClient,
  cwd: string,
  resumeThreadId: string | undefined,
  config: Record<string, unknown>
): Promise<unknown> => {
  if (resumeThreadId === undefined) return client.request("thread/start", { cwd, config })

  return client.request("thread/resume", { cwd, threadId: resumeThreadId, config })
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
  session.pendingPrompt?.resolve({ stopReason: "cancelled" })
  session.pendingPrompt = undefined
  cancelPendingQuestions(session)
  void session.emit({
    kind: "session.error",
    payload: { message: error.message },
    subjectId: session.key
  })
}
