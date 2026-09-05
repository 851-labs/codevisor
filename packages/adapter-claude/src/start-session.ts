import type {
  getSessionInfo as sdkGetSessionInfo,
  Options as ClaudeOptions
} from "@anthropic-ai/claude-agent-sdk"
import { randomUUID } from "node:crypto"
import {
  runtimeError,
  type CreateSessionOptions,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { emitBackgroundTasks, wrapBackgroundBash } from "./background-tasks.js"
import { emitAuthoritativeDiff } from "./diff-stats.js"
import { handleMessage } from "./messages.js"
import { applyClaudeModelFromProvider, currentClaudeModelFor, metadataFor } from "./models.js"
import { holdClaudeApproval, holdClaudePlanApproval, holdClaudeQuestion } from "./questions.js"
import { InputQueue, type ClaudeQueryFn, type ClaudeSession } from "./session.js"
import { applyTaskCreate, emitTaskPlanUpdate } from "./tasks.js"
import { failDeferredPrompts, finishActiveTurn } from "./turn-lifecycle.js"

/// Effort levels the CLI's flag settings accept. `max` is valid (verified
/// against a live CLI) even though the SDK's `Settings` type lags its own
/// `EffortLevel` union.
const SETTABLE_EFFORT_LEVELS = new Set(["low", "medium", "high", "xhigh", "max"])

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
  readonly wrapCommand: ((key: string, command: string) => string) | undefined
}

/// Session/query startup extracted from makeClaudeProvider as a deps-factory
/// (the makeSkillsOperations pattern): the startSession body is unchanged, its
/// closed-over provider dependencies are injected.
export const makeStartSession = (deps: StartSessionDeps) => {
  const {
    environment,
    getSessionInfo,
    guardVersion,
    locateClaude,
    queryFn,
    readFile,
    wrapCommand
  } = deps

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

    // In streaming-input mode the SDK emits `system:init` only once the first
    // user message is sent, so session creation must not block on it. The
    // session id is assigned up front via the CLI's --session-id flag; init
    // later confirms it and fills in the model.
    const sessionKey = resume ?? randomUUID()
    const input = new InputQueue()
    const abort = new AbortController()
    const accountEnv = Object.fromEntries(
      Object.entries(environment.env).filter(
        (entry): entry is [string, string] => typeof entry[1] === "string"
      )
    )
    if (account?.profileKind === "managed") {
      for (const name of CLAUDE_AUTH_OVERRIDE_ENV_VARS) delete accountEnv[name]
    }
    Object.assign(accountEnv, account?.env)
    // Filled in below; the hook and pump close over it.
    let session: ClaudeSession | undefined
    const options: ClaudeOptions = {
      abortController: abort,
      cwd,
      env: accountEnv,
      includePartialMessages: true,
      pathToClaudeCodeExecutable: claudePath,
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
      // The CLI invokes this only when the active permission mode requires a
      // human decision (never in the bypassPermissions default). Questions
      // and approvals both surface through the blocking question pipeline.
      canUseTool: async (toolName, toolInput) => {
        if (session === undefined) {
          return { behavior: "allow", updatedInput: toolInput }
        }
        if (toolName === "AskUserQuestion") {
          return holdClaudeQuestion(session, toolInput)
        }
        // ExitPlanMode's approval is the "implement this plan?" decision — give
        // it a dedicated plan-approval question the client can render nicely,
        // not a bare "Allow ExitPlanMode?" permission row.
        if (toolName === "ExitPlanMode") {
          return holdClaudePlanApproval(session, toolInput)
        }
        return holdClaudeApproval(session, toolName, toolInput)
      },
      permissionMode: "bypassPermissions",
      hooks: {
        PostToolUse: [
          {
            hooks: [
              async (hookInput) => {
                if (hookInput.hook_event_name === "PostToolUse" && session !== undefined) {
                  emitAuthoritativeDiff(session, hookInput, readFile)
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
        ],
        // Hooks run in every permission mode (unlike canUseTool, which the
        // bypassPermissions default never invokes) — the only reliable seam
        // for rewriting background Bash through the server's terminal host.
        ...(wrapCommand === undefined
          ? {}
          : {
              PreToolUse: [
                {
                  matcher: "Bash",
                  hooks: [
                    async (hookInput, toolUseID) => {
                      if (
                        hookInput.hook_event_name !== "PreToolUse" ||
                        session === undefined ||
                        toolUseID === undefined
                      ) {
                        return {}
                      }
                      return wrapBackgroundBash(
                        session,
                        hookInput.tool_input,
                        toolUseID,
                        wrapCommand
                      )
                    }
                  ]
                }
              ]
            })
      },
      ...(resume === undefined ? { extraArgs: { "session-id": sessionKey } } : { resume })
    }
    const q = queryFn({ prompt: input, options })

    const created: ClaudeSession = {
      abort,
      truncationCount: 0,
      transientRetries: 0,
      lastAssistantError: undefined,
      lastErrorText: undefined,
      lastUsageLimitText: undefined,
      latestRateLimitInfo: undefined,
      latestContextUsage: undefined,
      activeContextCompactionId: undefined,
      accumulators: new Map(),
      backgroundShellKeys: new Map(),
      backgroundTasks: new Map(),
      hiddenBackgroundTaskIds: new Set(),
      currentEffort: "default",
      currentMessageId: undefined,
      currentMessageTextStreamed: false,
      currentModel: "",
      currentSpeed: "standard",
      cwd,
      emit,
      getSessionInfo,
      initiatedBy: "user",
      input,
      interruptRequested: false,
      key: sessionKey,
      lastHarnessTitle: undefined,
      models: [],
      openToolCalls: new Set(),
      taskToolUses: new Map(),
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
      turnActive: false,
      turnId: randomUUID()
    }
    session = created
    // A fresh session has no background work by definition; this snapshot
    // clears any stale "running" state a client may replay from a previous
    // server process's event log.
    emitBackgroundTasks(created)

    const pump = async (): Promise<void> => {
      let streamFailure: string | undefined
      try {
        for await (const message of q) {
          if (message.type === "system" && message.subtype === "init") {
            applyClaudeModelFromProvider(created, message.model)
            if (message.fast_mode_state !== undefined) {
              created.currentSpeed = message.fast_mode_state === "on" ? "fast" : "standard"
            }
            continue
          }
          if (
            !created.retired &&
            message.type === "system" &&
            message.subtype === "model_refusal_fallback"
          ) {
            // The selected model's safety classifiers declined the request and
            // Claude Code re-ran the turn on a fallback model. Handled here
            // rather than in `handleSystemMessage` for the same reason `init`
            // is: correcting the model needs this scope's `metadataFor` and
            // model-matching helpers.
            //
            // Two separate emits, deliberately: the client's `session.updated`
            // dispatch duck-types the payload and stops at the first arm that
            // matches, so folding the notice and the option snapshot into one
            // payload would drop whichever arm loses.
            const fallbackModel = applyClaudeModelFromProvider(created, message.fallback_model)
            void created.emit({
              kind: "session.updated",
              payload: {
                modelFallback: {
                  originalModel: message.original_model,
                  // Prefer the picker's canonical value when the provider's
                  // concrete id can be reconciled with it. If it cannot, keep
                  // the provider id: reporting an unfamiliar fallback is more
                  // truthful than substituting the model that just refused.
                  fallbackModel,
                  // Open string on the wire — new categories ship ahead of
                  // schema updates, so this passes through untouched.
                  category: message.api_refusal_category ?? null
                }
              },
              subjectId: created.key
            })
            // The swap is sticky for the session, so a picker still
            // advertising the original model would be lying for every later
            // turn. Re-emitting the whole snapshot also refreshes the
            // effort/speed lists, which derive from the current model.
            void created.emit({
              kind: "session.updated",
              payload: {
                configId: "model",
                configOptions: metadataFor(created).configOptions,
                value: created.currentModel
              },
              subjectId: created.key
            })
            continue
          }
          if (!created.retired) handleMessage(created, message, readFile)
        }
      } catch (cause) {
        const failure = cause instanceof Error ? cause.message : String(cause)
        streamFailure = failure
        // A live turn is closed below through the normal terminal event so
        // the failure is attached durably to that assistant response. Only a
        // stream failure outside a turn remains a session-level error.
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
        created.streamEnded = true
        // The SDK stream ended (query closed, aborted, or threw) with a turn
        // still in flight and no final `result` to close it. Without this the
        // client would show "working"/"Thinking…" forever and the awaited
        // prompt would never settle. End the turn defensively so state can't
        // get wedged.
        if (created.turnActive) {
          if (created.interruptRequested) {
            await finishActiveTurn(created, "cancelled")
          } else {
            await finishActiveTurn(
              created,
              "end_turn",
              streamFailure ?? "The Claude connection ended unexpectedly.",
              true
            )
          }
        }
      }
    }
    pump().catch(() => undefined)

    // Best-effort model list: the control channel usually answers before the
    // first turn, but session creation must not hang on it.
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
        currentClaudeModelFor(created)
      } else {
        // Losing the race does not cancel the request: the CLI still answers
        // on its control channel, typically a few seconds later on a busy
        // machine. Without the list `metadataFor` emits no config options at
        // all (effort and speed derive from the current model), so the picker
        // would vanish for the life of the session. Adopt the late list and
        // publish it through the same config-update event a model change
        // uses; the client folds it in and the picker appears late instead
        // of never.
        modelList.then(
          (lateModels) => {
            if (created.retired || created.models.length > 0) return
            adoptModelList(created, lateModels)
            // Init may already have reported the concrete model id; reconcile
            // it against the picker rather than resetting to the first entry.
            applyClaudeModelFromProvider(created, created.currentModel)
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

type SupportedModel = Awaited<ReturnType<ClaudeSession["q"]["supportedModels"]>>[number]

/// The CLI's "default" pseudo-model is an alias, not a model — the picker
/// shows real models only.
const adoptModelList = (session: ClaudeSession, models: ReadonlyArray<SupportedModel>): void => {
  session.models = models
    .filter((model) => model.value !== "default")
    .map((model) => ({
      name: model.displayName,
      supportedEffortLevels: (model.supportsEffort === true
        ? (model.supportedEffortLevels ?? [])
        : []
      ).filter((level) => SETTABLE_EFFORT_LEVELS.has(level)),
      supportsFastMode: model.supportsFastMode === true,
      value: model.value
    }))
}
