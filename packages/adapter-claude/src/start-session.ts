import { randomUUID } from "node:crypto"

import type {
  getSessionInfo as sdkGetSessionInfo,
  Options as ClaudeOptions
} from "@anthropic-ai/claude-agent-sdk"
import {
  runtimeError,
  type CreateSessionOptions,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"

import { emitBackgroundTasks } from "./background-tasks.js"
import { emitAuthoritativeDiff } from "./diff-stats.js"
import { handleMessage } from "./messages.js"
import {
  adoptModelList,
  alignStartModel,
  applyClaudeModelFromProvider,
  claudeStartOptions,
  emitModelFallback,
  currentClaudeModelFor,
  metadataFor,
  resolveClaudeModel,
  SETTABLE_EFFORT_LEVELS
} from "./models.js"
import { holdClaudeApproval, holdClaudePlanApproval, holdClaudeQuestion } from "./questions.js"
import {
  InputQueue,
  type ClaudeModel,
  type ClaudeQuery,
  type ClaudeQueryFn,
  type ClaudeSession
} from "./session.js"
import {
  learnClaudeSkills,
  makeClaudeCommandCatalog,
  supersededSkillsOff,
  trackClaudeSkills
} from "./skills.js"
import { resumeSessionAfterStreamDeath } from "./stream-recovery.js"
import { claudeConfigDir, type SubagentTranscripts } from "./subagent-transcripts.js"
import { applyTaskCreate, emitTaskPlanUpdate } from "./tasks.js"
import { failDeferredPrompts, finishActiveTurn } from "./turn-lifecycle.js"

const CLAUDE_AUTH_OVERRIDE_ENV_VARS = [
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
  "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
] as const

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
  let knownModels: ReadonlyArray<ClaudeModel> = []
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
    const accountEnv = Object.fromEntries(
      Object.entries(await environment.envFor(cwd)).filter(
        (entry): entry is [string, string] => typeof entry[1] === "string"
      )
    )
    if (account?.profileKind === "managed") {
      for (const name of CLAUDE_AUTH_OVERRIDE_ENV_VARS) delete accountEnv[name]
    }
    for (const name of account?.unsetEnv ?? []) delete accountEnv[name]
    Object.assign(accountEnv, account?.env)
    const saved = sessionOptions?.configSelections ?? {}
    const savedModel =
      saved.model === undefined || knownModels.length === 0
        ? saved.model
        : resolveClaudeModel(knownModels, saved.model)?.value
    const startOptions = claudeStartOptions({
      effort: saved.effort,
      model: savedModel,
      speed: saved.speed,
      ...(toolGateway === undefined ? {} : { skillOverrides: supersededSkillsOff })
    })
    const nativeToolArgs: Record<string, string | null> =
      toolGateway === undefined ? {} : { "no-chrome": null }
    let session: ClaudeSession | undefined
    const options: ClaudeOptions = {
      ...startOptions,
      abortController: abort,
      cwd,
      env: accountEnv,
      includePartialMessages: true,
      pathToClaudeCodeExecutable: claudePath,
      systemPrompt: { type: "preset", preset: "claude_code" },
      ...(toolGateway === undefined
        ? {}
        : {
            strictMcpConfig: true,
            mcpServers: {
              [toolGateway.name]: {
                type: "http" as const,
                url: toolGateway.url,
                headers: { Authorization: `Bearer ${toolGateway.bearerToken}` }
              }
            }
          }),
      canUseTool: async (toolName, toolInput, check) => {
        if (session === undefined) {
          return { behavior: "allow", updatedInput: toolInput }
        }
        if (toolName === "AskUserQuestion") {
          return holdClaudeQuestion(session, toolInput)
        }
        if (toolName === "ExitPlanMode") {
          return holdClaudePlanApproval(session, toolInput)
        }
        if (session.currentModeId === "bypassPermissions") {
          console.error(
            `[claude] auto-allowed ${toolName} escalated under bypassPermissions` +
              (check.agentID === undefined ? "" : ` agent=${check.agentID}`) +
              `: ${check.decisionReason ?? "no reason given"}`
          )
          return { behavior: "allow", updatedInput: toolInput }
        }
        return holdClaudeApproval(session, toolName, toolInput)
      },
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      hooks: {
        PostToolUse: [
          {
            hooks: [
              async (hookInput) => {
                if (hookInput.hook_event_name === "PostToolUse" && session !== undefined) {
                  emitAuthoritativeDiff(session, hookInput)
                }
                return {}
              }
            ]
          }
        ],
        TaskCreated: [
          {
            hooks: [
              async (hookInput) => {
                if (
                  hookInput.hook_event_name === "TaskCreated" &&
                  session !== undefined &&
                  applyTaskCreate(session.tasks, hookInput.task_id, {
                    description: hookInput.task_description,
                    subject: hookInput.task_subject
                  })
                ) {
                  emitTaskPlanUpdate(session)
                }
                return {}
              }
            ]
          }
        ],
        TaskCompleted: [
          {
            hooks: [
              async (hookInput) => {
                if (hookInput.hook_event_name === "TaskCompleted" && session !== undefined) {
                  const existing = session.tasks.get(hookInput.task_id)
                  if (existing !== undefined && existing.status !== "completed") {
                    session.tasks.set(hookInput.task_id, { ...existing, status: "completed" })
                    emitTaskPlanUpdate(session)
                  }
                }
                return {}
              }
            ]
          }
        ]
      },
      ...(resume === undefined
        ? { extraArgs: { ...nativeToolArgs, "session-id": sessionKey } }
        : { ...(toolGateway === undefined ? {} : { extraArgs: nativeToolArgs }), resume })
    }
    const q = queryFn({ prompt: input, options })

    const created: ClaudeSession = {
      abort,
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
      currentEffort:
        saved.effort !== undefined && SETTABLE_EFFORT_LEVELS.has(saved.effort)
          ? saved.effort
          : "default",
      currentMessageId: undefined,
      currentMessageTextStreamed: false,
      currentModel: startOptions.model ?? "",
      currentModeId: "bypassPermissions",
      currentSpeed: saved.speed === "fast" ? "fast" : "standard",
      cwd,
      emit,
      getSessionInfo,
      initiatedBy: "user",
      input,
      interruptRequested: false,
      key: sessionKey,
      lastHarnessTitle: undefined,
      models: [],
      skills: { catalog: commandCatalog, claudePath, commands: undefined, snapshot: undefined },
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
      q,
      retired: false,
      streamEnded: false,
      sdkSessionId: sessionKey,
      subagentMessageIds: new Map(),
      subagentLastTexts: new Map(),
      forkedCommands: new Map(),
      forkedCommandReplyPending: false,
      subagentTranscripts: subagentTranscripts(claudeConfigDir(accountEnv)),
      turnActive: false,
      turnId: randomUUID()
    }
    session = created
    void emitBackgroundTasks(created)

    const resumeAfterStreamDeath = (): Promise<boolean> =>
      resumeSessionAfterStreamDeath(created, {
        options,
        pump,
        queryFn
      })

    const pump = async (query: ClaudeQuery): Promise<void> => {
      let streamFailure: string | undefined
      try {
        for await (const message of query) {
          if (message.type === "system" && message.subtype === "init") {
            learnClaudeSkills(created, message)
            const expectedModel = created.currentModel
            applyClaudeModelFromProvider(created, message.model)
            if (message.fast_mode_state !== undefined) {
              created.currentSpeed = message.fast_mode_state === "on" ? "fast" : "standard"
            }
            if (
              !created.retired &&
              expectedModel.length > 0 &&
              created.models.length > 0 &&
              created.currentModel !== expectedModel
            ) {
              emitModelFallback(created, expectedModel, created.currentModel, null)
            }
            continue
          }
          if (
            !created.retired &&
            message.type === "system" &&
            message.subtype === "model_refusal_fallback"
          ) {
            const fallbackModel = applyClaudeModelFromProvider(created, message.fallback_model)
            emitModelFallback(
              created,
              message.original_model,
              fallbackModel,
              message.api_refusal_category ?? null
            )
            continue
          }
          if (!created.retired) handleMessage(created, message, readFile)
        }
      } catch (cause) {
        const failure = cause instanceof Error ? cause.message : String(cause)
        streamFailure = failure
        if (!created.turnActive && !created.retired) {
          created.pendingPrompt?.reject(runtimeError("prompt", cause))
          created.pendingPrompt = undefined
          failDeferredPrompts(created, runtimeError("prompt", cause))
          void created.emit({
            kind: "session.error",
            payload: { message: failure },
            subjectId: created.key
          })
        }
      } finally {
        if (created.q === query) {
          created.streamEnded = true
          if (created.turnActive) {
            if (created.interruptRequested) {
              await finishActiveTurn(created, "cancelled")
            } else if (!(await resumeAfterStreamDeath())) {
              await finishActiveTurn(created, "end_turn", {
                retryable: true,
                stopDetail: streamFailure ?? "The Claude connection ended unexpectedly."
              })
            }
          }
        }
      }
    }
    pump(q).catch(() => undefined)

    trackClaudeSkills(created)
    try {
      const modelList = q.supportedModels()
      let timeout: ReturnType<typeof setTimeout> | undefined
      const models = await Promise.race([
        modelList,
        new Promise<undefined>((resolve) => {
          timeout = setTimeout(() => resolve(undefined), sessionOptions?.modelListTimeoutMs ?? 3000)
        })
      ]).finally(() => clearTimeout(timeout))
      if (models !== undefined) {
        adoptModelList(created, models)
        knownModels = created.models
        currentClaudeModelFor(created)
        await alignStartModel(created, startOptions.model)
      } else {
        modelList.then(
          (lateModels) => {
            if (created.retired || created.models.length > 0) return
            adoptModelList(created, lateModels)
            knownModels = created.models
            applyClaudeModelFromProvider(created, created.currentModel)
            void alignStartModel(created, startOptions.model)
            void created.emit({
              kind: "session.updated",
              payload: {
                configId: "model",
                configOptions: metadataFor(created).configOptions,
                value: created.currentModel
              },
              subjectId: created.key
            })
          },
          () => undefined
        )
      }
    } catch {
      created.models = []
    }
    return created
  }
  return startSession
}
