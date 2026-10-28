import { randomUUID } from "node:crypto"

import type { getSessionInfo as sdkGetSessionInfo } from "@anthropic-ai/claude-agent-sdk"
import type {
  CreateSessionOptions,
  HarnessAccountContext,
  HarnessDefinition,
  ProviderEnvironment,
  RuntimeEmit,
  ToolGatewayConfig
} from "@codevisor/agent-runtime"

import { claudeAccountEnv } from "./account-env.js"
import { emitBackgroundTasks } from "./background-tasks.js"
import { alignStartModel, isSettableEffort } from "./models.js"
import { claudeQueryOptions } from "./query-options.js"
import { InputQueue, type ClaudeQuery, type ClaudeQueryFn, type ClaudeSession } from "./session.js"
import { makeClaudeCommandCatalog, trackClaudeSkills, type ClaudeCommandCatalog } from "./skills.js"
import {
  adoptListedModels,
  adoptModelsWhenListed,
  modelsWithin,
  savedStartOptions,
  startEffortFor,
  type ConfigSelections,
  type KnownClaudeModels
} from "./start-models.js"
import { makeStreamPump } from "./stream-pump.js"
import { claudeConfigDir, type SubagentTranscripts } from "./subagent-transcripts.js"

export interface StartSessionDeps {
  readonly environment: ProviderEnvironment
  readonly getSessionInfo: typeof sdkGetSessionInfo
  readonly guardVersion: (claudePath: string) => Promise<void>
  readonly locateClaude: (definition: HarnessDefinition) => string
  readonly queryFn: ClaudeQueryFn
  readonly readFile: (path: string) => string | undefined
  readonly subagentTranscripts: (configDir: string) => SubagentTranscripts
}

export const makeStartSession = (deps: StartSessionDeps) => {
  const {
    environment,
    getSessionInfo,
    guardVersion,
    locateClaude,
    queryFn,
    readFile,
    subagentTranscripts
  } = deps
  const knownModels: KnownClaudeModels = { list: [] }
  const effortDefaults = new Map<string, string>()
  const commandCatalog = makeClaudeCommandCatalog()

  const startSession = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    resume: string | undefined,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig,
    sessionOptions?: CreateSessionOptions
  ): Promise<ClaudeSession> => {
    const claudePath = locateClaude(definition)
    await guardVersion(claudePath)

    const sessionKey = resume ?? randomUUID()
    const input = new InputQueue()
    const abort = new AbortController()
    const env = claudeAccountEnv(await environment.envFor(cwd), account)
    const saved = sessionOptions?.configSelections ?? {}
    const startOptions = savedStartOptions(saved, knownModels.list, effortDefaults, toolGateway)

    let session: ClaudeSession | undefined
    const options = claudeQueryOptions({
      abort,
      claudePath,
      currentSession: () => session,
      cwd,
      env,
      resume,
      sessionKey,
      startOptions,
      toolGateway
    })
    const q = queryFn({ prompt: input, options })

    const created = newClaudeSession({
      abort,
      claudePath,
      commandCatalog,
      cwd,
      effortDefaults,
      emit,
      env,
      getSessionInfo,
      input,
      key: sessionKey,
      q,
      saved,
      startModel: startOptions.model,
      subagentTranscripts
    })
    session = created
    void emitBackgroundTasks(created)
    makeStreamPump(created, { options, queryFn, readFile })(q).catch(() => undefined)
    trackClaudeSkills(created)

    try {
      const modelList = q.supportedModels()
      const models = await modelsWithin(modelList, sessionOptions)
      if (models !== undefined) {
        adoptListedModels(created, models, knownModels)
        await alignStartModel(created, startOptions.model)
      } else {
        adoptModelsWhenListed(created, modelList, knownModels, startOptions.model)
      }
    } catch {
      created.models = []
    }
    return created
  }
  return startSession
}

interface ClaudeSessionSeed {
  readonly abort: AbortController
  readonly claudePath: string
  readonly commandCatalog: ClaudeCommandCatalog
  readonly cwd: string
  readonly effortDefaults: Map<string, string>
  readonly emit: RuntimeEmit
  readonly env: Record<string, string>
  readonly getSessionInfo: typeof sdkGetSessionInfo
  readonly input: InputQueue
  readonly key: string
  readonly q: ClaudeQuery
  readonly saved: ConfigSelections
  readonly startModel: string | undefined
  readonly subagentTranscripts: (configDir: string) => SubagentTranscripts
}

const newClaudeSession = (seed: ClaudeSessionSeed): ClaudeSession => ({
  abort: seed.abort,
  truncationCount: 0,
  transientRetries: 0,
  streamRecoveries: 0,
  lastAssistantError: undefined,
  lastErrorText: undefined,
  lastUsageLimitText: undefined,
  latestRateLimitInfo: undefined,
  latestContextUsage: undefined,
  activeContextCompactionId: undefined,
  accumulators: new Map(),
  backgroundTasks: new Map(),
  hiddenBackgroundTaskIds: new Set(),
  currentEffort: startEffortFor(seed.saved, seed.startModel, seed.effortDefaults),
  effortPicked: isSettableEffort(seed.saved.effort),
  effortDefaults: seed.effortDefaults,
  onDefaultModel: seed.startModel === undefined,
  currentMessageId: undefined,
  currentMessageTextStreamed: false,
  currentModel: seed.startModel ?? "",
  currentModeId: "bypassPermissions",
  currentSpeed: seed.saved.speed === "fast" ? "fast" : "standard",
  cwd: seed.cwd,
  emit: seed.emit,
  getSessionInfo: seed.getSessionInfo,
  initiatedBy: "user",
  input: seed.input,
  interruptRequested: false,
  key: seed.key,
  lastHarnessTitle: undefined,
  models: [],
  skills: {
    catalog: seed.commandCatalog,
    claudePath: seed.claudePath,
    commands: undefined,
    snapshot: undefined
  },
  openToolCalls: new Set(),
  taskToolUses: new Map(),
  skillCalls: new Map(),
  tasks: new Map(),
  pendingPrompt: undefined,
  deferredPrompts: [],
  turnCompletion: undefined,
  cancelInFlight: undefined,
  pendingUserCommands: 0,
  currentGoal: undefined,
  pendingQuestions: new Map(),
  q: seed.q,
  retired: false,
  streamEnded: false,
  sdkSessionId: seed.key,
  subagentMessageIds: new Map(),
  subagentLastTexts: new Map(),
  forkedCommands: new Map(),
  forkedCommandReplyPending: false,
  subagentTranscripts: seed.subagentTranscripts(claudeConfigDir(seed.env)),
  turnActive: false,
  turnId: randomUUID()
})
