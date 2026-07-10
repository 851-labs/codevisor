import {
  query as sdkQuery,
  type Options as ClaudeOptions,
  type Query,
  type SDKMessage,
  type SDKUserMessage
} from "@anthropic-ai/claude-agent-sdk"
import type {
  DiffStat,
  QuestionSpec,
  SessionConfigOption,
  SessionGoal,
  SessionModeState
} from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { readFileSync } from "node:fs"
import { listClaudeAgentSessions } from "../agent-sessions.js"
import { isAbsolute, resolve } from "node:path"
import { Effect } from "effect"
import { INLINE_IMAGE_MEDIA_TYPES, withAttachmentNotes } from "../attachments.js"
import {
  backgroundTerminalKey,
  type BackgroundTerminalIntegration
} from "../background-terminals.js"
import { diffStatsFromTexts, lineCount } from "../diff-stats.js"
import { findKnownModel, highestThinkingLevel, sanitizeModelValue } from "./model-selection.js"
import {
  adapterPromise,
  normalizePromptInput,
  runtimeError,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type CreatedAgentSession,
  type HarnessDefinition,
  type LoadedAgentSession,
  type PromptAttachmentInput,
  type PromptInput,
  type ProviderEnvironment,
  type QuestionAnswer,
  type RuntimeEmit,
  type RuntimeEvent
} from "../types.js"

/// Claude Code versions older than this predate the control-protocol features
/// the Agent SDK relies on (streaming input, setModel/setPermissionMode).
const MINIMUM_CLAUDE_VERSION = "2.0.0"

/// Streaming diff-stat updates are throttled per tool call; every event is
/// persisted server-side, so unbounded input_json_delta emission would bloat
/// the events table.
const STREAM_STATS_INTERVAL_MS = 250

/// Effort levels the CLI's flag settings accept. `max` is valid (verified
/// against a live CLI) even though the SDK's `Settings` type lags its own
/// `EffortLevel` union.
const SETTABLE_EFFORT_LEVELS = new Set(["low", "medium", "high", "xhigh", "max"])

/// Tools rendered as plans instead of tool calls: TodoWrite carries the step
/// checklist (`input.todos`), ExitPlanMode the plan-mode plan document
/// (`input.plan`). Their generic tool-call lifecycle is suppressed entirely —
/// the client renders the plan updates instead (same posture as the
/// codex-acp/claude-acp adapters).
const PLAN_TOOLS = new Set(["TodoWrite", "ExitPlanMode"])

/// Tools whose generic tool-call lifecycle never reaches the wire: plan tools
/// surface as plan updates, AskUserQuestion as a blocking `question` event
/// handled through canUseTool.
const HIDDEN_TOOLS = new Set([...PLAN_TOOLS, "AskUserQuestion"])

/// Model-level stop reasons that mean "I ran out of room, not out of work":
/// the assistant message was truncated by the per-response output-token cap.
/// The SDK reports this as an ordinary `success` result, so on its own the
/// provider would end the turn — the "Claude just stopped mid-task" symptom,
/// where the user had to nudge it with "continue" by hand. The provider resumes
/// automatically instead; see `handleResult`.
const TRUNCATION_STOP_REASONS = new Set(["max_tokens"])

/// SDK assistant-message `error` values that will fail identically on retry —
/// the request/credentials/model are wrong. These end the turn and surface a
/// reason. Everything else on `error_during_execution` (overloaded, rate_limit,
/// server_error, `unknown`, or no error at all) is treated as transient and
/// retried with backoff — a bounded retry is the safe default so we never
/// silently swallow a recoverable failure.
const PERMANENT_ASSISTANT_ERRORS = new Set([
  "authentication_failed",
  "oauth_org_not_allowed",
  "billing_error",
  "invalid_request",
  "model_not_found"
])

/// SDK assistant-message `error` values that are transient (the API was busy,
/// not the request being wrong) — worth an automatic retry. `unknown` is
/// included so an unclassified `error_during_execution` still retries rather
/// than surfacing immediately.
const TRANSIENT_ASSISTANT_ERRORS = new Set(["overloaded", "rate_limit", "server_error", "unknown"])

/// A transient API failure can also arrive with NO structured error — the CLI
/// renders it as a plain assistant text message ending on a stop sequence
/// (observed: `API Error: 529 Overloaded …`). Match the CLI's error-line format
/// for 429 / 5xx (and a bare "overloaded"); 4xx client errors are NOT matched,
/// since those are permanent. Used only alongside a `stop_sequence` ending.
const API_ERROR_TEXT = /^\s*API Error:\s*(429|5\d\d)\b|^\s*overloaded\b/i

/// Silent truncation continuations allowed per turn: an output-token-truncated
/// response legitimately has more to say, so this is generous. Past it the turn
/// ends and surfaces the truncation.
const MAX_TRUNCATION_CONTINUATIONS = 12

/// Visible transient retries allowed per turn (529 overload, rate-limit, server
/// error), on top of the SDK's own internal retries. Past it the turn ends and
/// the error is surfaced to the user.
const MAX_TRANSIENT_RETRIES = 3

/// Escalating backoff before a *transient* retry (~1s, 2s, 4s), so we don't
/// hammer an overloaded API. Truncation continuations use no delay.
const RECOVERY_BACKOFF_BASE_MS = 1000
const RECOVERY_BACKOFF_CAP_MS = 8000
const recoveryBackoffMs = (retryIndex: number): number =>
  Math.min(RECOVERY_BACKOFF_BASE_MS * 2 ** retryIndex, RECOVERY_BACKOFF_CAP_MS)

/// The nudge pushed to resume a recoverable turn — the same thing a user would
/// type. Pushed straight into the SDK input queue, so it never surfaces as a
/// visible user message (the `user` echo carries no tool_result to forward).
const CONTINUE_PROMPT = "Please continue."

const PLAN_ENTRY_STATUSES = new Set(["pending", "in_progress", "completed"])

/// Maps TodoWrite's todos into wire plan entries. Lenient: malformed todos
/// are skipped, unknown statuses degrade to pending. Priority is fixed at
/// "medium" — Claude todos carry no priority (mirrors claude-agent-acp).
const planEntriesFromTodos = (
  todos: ReadonlyArray<unknown>
): Array<{ content: string; priority: string; status: string }> =>
  todos.flatMap((todo) => {
    if (!isRecord(todo) || typeof todo.content !== "string" || todo.content.length === 0) {
      return []
    }
    return [
      {
        content: todo.content,
        priority: "medium",
        status:
          typeof todo.status === "string" && PLAN_ENTRY_STATUSES.has(todo.status)
            ? todo.status
            : "pending"
      }
    ]
  })

interface ClaudeModel {
  readonly value: string
  readonly name: string
  readonly supportedEffortLevels: ReadonlyArray<string>
  readonly supportsFastMode: boolean
}

type ClaudeContentBlock = Exclude<SDKUserMessage["message"]["content"], string>[number]

const isInlineForClaude = (attachment: PromptAttachmentInput): boolean =>
  (attachment.kind === "image" && INLINE_IMAGE_MEDIA_TYPES.has(attachment.mimeType)) ||
  attachment.mimeType === "application/pdf"

/// Builds the user-message content blocks: inline what the Anthropic API
/// accepts (images, PDFs) so the model sees the content, and note EVERY
/// attachment's materialized temp-file path in the text — including inline
/// images — so the agent also knows where each file lives on disk (to copy it
/// into the repo, re-read it, etc.).
const claudeContent = (input: PromptInput): Array<ClaudeContentBlock> => {
  const attachments = input.attachments ?? []
  const inline = attachments.filter(isInlineForClaude)
  const text = withAttachmentNotes(input.text, attachments)
  const blocks: Array<ClaudeContentBlock> = []
  if (text !== "" || inline.length === 0) {
    blocks.push({ text, type: "text" })
  }
  for (const attachment of inline) {
    const data = attachment.data.toString("base64")
    blocks.push(
      attachment.mimeType === "application/pdf"
        ? { source: { data, media_type: "application/pdf", type: "base64" }, type: "document" }
        : {
            source: {
              data,
              media_type: attachment.mimeType as "image/png",
              type: "base64"
            },
            type: "image"
          }
    )
  }
  return blocks
}

// "Always Ask" (not the CLI's internal "default") mirrors the naming the
// claude-agent-acp adapter ships; a bare "Default" tells the user nothing.
const PERMISSION_MODES: SessionModeState = {
  currentModeId: "bypassPermissions",
  availableModes: [
    {
      id: "default",
      name: "Always Ask",
      description: "Asks before editing files or running commands.",
      canonicalId: "ask"
    },
    {
      id: "acceptEdits",
      name: "Accept Edits",
      description: "Edits files without asking; still asks before running commands.",
      canonicalId: "autoEdit"
    },
    {
      id: "plan",
      name: "Plan",
      description: "Reads and plans only; presents a plan before making changes.",
      canonicalId: "plan"
    },
    {
      id: "bypassPermissions",
      name: "Bypass Permissions",
      description: "Edits files and runs commands without asking.",
      canonicalId: "fullAccess"
    }
  ]
}

export type ClaudeQueryFn = (input: {
  prompt: AsyncIterable<SDKUserMessage>
  options: ClaudeOptions
}) => Query

export interface ClaudeProviderConfig {
  /// Injectable for tests: scripted SDK message streams instead of a real CLI.
  readonly queryFn?: ClaudeQueryFn
  readonly readFile?: (path: string) => string | undefined
  readonly checkVersion?: (claudePath: string) => Promise<string>
  /// When set (and `wrapCommand` is present), background Bash commands are
  /// rewritten to tee their output through a server-owned terminal so clients
  /// can attach to the live process; foreground commands are untouched.
  readonly backgroundTerminals?: BackgroundTerminalIntegration
}

/// Push-based AsyncIterable used as the SDK's streaming prompt input; keeping
/// it open keeps the Claude process alive across turns, which is what lets
/// between-turn/background output flow.
class InputQueue implements AsyncIterable<SDKUserMessage> {
  private buffer: Array<SDKUserMessage> = []
  private waiting: ((value: IteratorResult<SDKUserMessage>) => void) | undefined
  private ended = false

  push(message: SDKUserMessage): void {
    if (this.ended) return
    const waiting = this.waiting
    if (waiting !== undefined) {
      this.waiting = undefined
      waiting({ done: false, value: message })
      return
    }
    this.buffer.push(message)
  }

  end(): void {
    this.ended = true
    const waiting = this.waiting
    if (waiting !== undefined) {
      this.waiting = undefined
      waiting({ done: true, value: undefined })
    }
  }

  [Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    return {
      next: (): Promise<IteratorResult<SDKUserMessage>> => {
        const buffered = this.buffer.shift()
        if (buffered !== undefined) {
          return Promise.resolve({ done: false, value: buffered })
        }
        if (this.ended) {
          return Promise.resolve({ done: true, value: undefined })
        }
        return new Promise((resolvePromise) => {
          this.waiting = resolvePromise
        })
      }
    }
  }
}

interface Deferred<A> {
  readonly promise: Promise<A>
  readonly resolve: (value: A) => void
  readonly reject: (error: unknown) => void
}

const deferred = <A>(): Deferred<A> => {
  let resolveFn!: (value: A) => void
  let rejectFn!: (error: unknown) => void
  const promise = new Promise<A>((resolvePromise, rejectPromise) => {
    resolveFn = resolvePromise
    rejectFn = rejectPromise
  })
  promise.catch(() => undefined)
  return { promise, reject: rejectFn, resolve: resolveFn }
}

/// Accumulates the streamed partial JSON of one tool_use input so edit tools
/// can report running added/removed line counts while the model is typing.
interface ToolInputAccumulator {
  readonly toolName: string
  json: string
  lastEmit: number
  lastStats: string
  /// The file path streamed so far, once extractable — drives live titles.
  titledPath: string | undefined
  /// For Write: the pre-edit file content, read once.
  oldContent: string | null | undefined
}

/// One in-flight background task (backgrounded shell, subagent, ...) tracked
/// from the SDK's `task_*` system messages. Emitted to clients as a full
/// snapshot on every change so the UI can show what the agent is waiting on.
interface BackgroundTaskEntry {
  readonly id: string
  description: string
  status: string
  readonly taskType: string
  readonly toolUseId?: string
  /// Set when the task's process streams through a server-owned terminal
  /// (background Bash rewritten by the PreToolUse hook).
  readonly terminalKey?: string
}

type ClaudeToolDecision =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string }

/// One blocking canUseTool ask (AskUserQuestion or a permission approval)
/// awaiting the human's answer. `resolve` settles the SDK's canUseTool
/// promise; `respond` builds the source-specific decision from the wire
/// answer (including dismissals).
interface PendingClaudeQuestion {
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly resolve: (result: ClaudeToolDecision) => void
  readonly respond: (answer: QuestionAnswer) => ClaudeToolDecision
}

interface ClaudeSession {
  /// The id the runtime and server know this session by (== SDK session id
  /// for new sessions; the requested id for resumed ones).
  readonly key: string
  readonly sdkSessionId: string
  readonly cwd: string
  readonly q: Query
  readonly input: InputQueue
  readonly emit: RuntimeEmit
  readonly abort: AbortController
  turnActive: boolean
  turnId: string
  initiatedBy: "user" | "agent"
  pendingPrompt: Deferred<{ stopReason: string }> | undefined
  interruptRequested: boolean
  /// Silent output-token-truncation continuations in the current turn (capped by
  /// MAX_TRUNCATION_CONTINUATIONS). Reset when a new turn starts.
  truncationCount: number
  /// Visible transient retries (529 overload / rate-limit / server error) in the
  /// current turn (capped by MAX_TRANSIENT_RETRIES). Reset when a new turn starts.
  transientRetries: number
  /// The most recent SDK assistant-message `error` (overloaded/rate_limit/
  /// authentication_failed/…) seen since the last `result`. Lets `handleResult`
  /// tell a transient failure (retry) from a permanent one (surface). Consumed
  /// and cleared on each `result`.
  lastAssistantError: string | undefined
  /// The human-readable API error text (e.g. "API Error: 529 Overloaded …") from
  /// a transient failure that arrived as plain text rather than a structured
  /// error. Shown in the answer slot (red) if all retries are exhausted.
  lastErrorText: string | undefined
  currentMessageId: string | undefined
  /// True once top-level text has streamed for `currentMessageId`. A tool_use
  /// block starting afterwards in the same message proves that text was
  /// preamble, not the final answer — the Anthropic stream has no upfront
  /// finality marker, so this is the earliest demotion signal available.
  currentMessageTextStreamed: boolean
  currentModel: string
  currentEffort: string
  currentSpeed: "standard" | "fast"
  models: ReadonlyArray<ClaudeModel>
  readonly accumulators: Map<string, ToolInputAccumulator>
  readonly openToolCalls: Set<string>
  /// Current message id per streaming subagent, keyed by the subagent's
  /// parent tool_use id — keeps subagent text spans stable across replay
  /// without touching the main agent's `currentMessageId`.
  readonly subagentMessageIds: Map<string, string>
  /// Cross-turn: background tasks legitimately outlive the turn that spawned
  /// them, so this is never cleared at turn end.
  readonly backgroundTasks: Map<string, BackgroundTaskEntry>
  /// tool_use id → server terminal key, recorded when the PreToolUse hook
  /// rewrites a background Bash command; consumed by `task_started` to stamp
  /// the task with its attachable terminal.
  readonly backgroundShellKeys: Map<string, string>
  /// question id → held AskUserQuestion canUseTool promise.
  readonly pendingQuestions: Map<string, PendingClaudeQuestion>
  /// Client-side goal snapshot. Claude Code's goal mode is driven through the
  /// CLI's `/goal` slash command (the SDK has no goal API yet), so HerdMan
  /// tracks the last state it set — the CLI gives no structured feedback.
  currentGoal: SessionGoal | undefined
}

export const makeClaudeProvider = (
  environment: ProviderEnvironment,
  config: ClaudeProviderConfig = {}
): AgentProvider => {
  const queryFn = config.queryFn ?? ((input) => sdkQuery(input))
  const readFile =
    config.readFile ??
    ((path: string): string | undefined => {
      try {
        return readFileSync(path, "utf8")
      } catch {
        return undefined
      }
    })
  const checkVersion = config.checkVersion ?? runClaudeVersion
  const wrapCommand = config.backgroundTerminals?.wrapCommand
  const versionCache = new Map<string, string>()

  const locateClaude = (definition: HarnessDefinition): string => {
    const binary = definition.detectBinaries[0] ?? "claude"
    const located = environment.locateExecutable(binary, environment.env)
    if (located === undefined) {
      throw new Error(`${binary} not found on PATH`)
    }
    return located
  }

  const guardVersion = async (claudePath: string): Promise<void> => {
    let version = versionCache.get(claudePath)
    if (version === undefined) {
      version = await checkVersion(claudePath)
      versionCache.set(claudePath, version)
    }
    if (compareVersions(version, MINIMUM_CLAUDE_VERSION) < 0) {
      throw new Error(
        `Claude Code ${version} is older than the required ${MINIMUM_CLAUDE_VERSION}. Update with: claude update`
      )
    }
  }

  const startSession = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    resume: string | undefined
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
    // Filled in below; the hook and pump close over it.
    let session: ClaudeSession | undefined
    const options: ClaudeOptions = {
      abortController: abort,
      cwd,
      includePartialMessages: true,
      pathToClaudeCodeExecutable: claudePath,
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
      accumulators: new Map(),
      backgroundShellKeys: new Map(),
      backgroundTasks: new Map(),
      currentEffort: "default",
      currentMessageId: undefined,
      currentMessageTextStreamed: false,
      currentModel: "",
      currentSpeed: "standard",
      cwd,
      emit,
      initiatedBy: "user",
      input,
      interruptRequested: false,
      key: sessionKey,
      models: [],
      openToolCalls: new Set(),
      pendingPrompt: undefined,
      currentGoal: undefined,
      pendingQuestions: new Map(),
      q,
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
      try {
        for await (const message of q) {
          if (message.type === "system" && message.subtype === "init") {
            applyClaudeModelFromProvider(created, message.model)
            if (message.fast_mode_state !== undefined) {
              created.currentSpeed = message.fast_mode_state === "on" ? "fast" : "standard"
            }
            continue
          }
          handleMessage(created, message, readFile)
        }
      } catch (cause) {
        const failure = cause instanceof Error ? cause.message : String(cause)
        created.pendingPrompt?.reject(runtimeError("prompt", cause))
        created.pendingPrompt = undefined
        void created.emit({
          kind: "session.error",
          payload: { message: failure },
          subjectId: created.key
        })
      } finally {
        // The SDK stream ended (query closed, aborted, or threw) with a turn
        // still in flight and no final `result` to close it. Without this the
        // client would show "working"/"Thinking…" forever and the awaited
        // prompt would never settle. End the turn defensively so state can't
        // get wedged.
        if (created.turnActive) {
          finishActiveTurn(created, created.interruptRequested ? "cancelled" : "end_turn")
        }
      }
    }
    pump().catch(() => undefined)

    // Best-effort model list: the control channel usually answers before the
    // first turn, but session creation must not hang on it.
    try {
      const models = await Promise.race([
        q.supportedModels(),
        new Promise<undefined>((resolvePromise) =>
          setTimeout(() => resolvePromise(undefined), 3000)
        )
      ])
      if (models !== undefined) {
        // The CLI's "default" pseudo-model is an alias, not a model — the
        // picker shows real models only.
        created.models = models
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
        currentClaudeModelFor(created)
      }
    } catch {
      created.models = []
    }
    return created
  }

  const metadataFor = (
    session: ClaudeSession
  ): {
    modes: SessionModeState
    configOptions: ReadonlyArray<SessionConfigOption>
    supportsGoals: boolean
  } => {
    const options: Array<SessionConfigOption> = []
    const currentModel = currentClaudeModelFor(session)
    if (session.models.length > 0) {
      options.push({
        category: "model",
        currentValue: currentModel?.value ?? session.models[0]?.value ?? session.currentModel,
        id: "model",
        name: "Model",
        options: session.models.map((model) => ({ name: model.name, value: model.value }))
      })
    }
    const effortLevels = effortLevelsFor(session)
    if (effortLevels.length > 0) {
      options.push({
        category: "thought_level",
        // No synthetic "Default" entry: until the user picks a level the CLI
        // runs at its own default ("high" on effort-capable models), so
        // surface that as the selection.
        currentValue: effortLevels.includes(session.currentEffort)
          ? session.currentEffort
          : defaultEffortFor(effortLevels),
        id: "effort",
        name: "Effort",
        options: effortLevels.map((level) => ({
          name: level === "xhigh" ? "X-High" : (level[0]?.toUpperCase() ?? "") + level.slice(1),
          value: level
        }))
      })
    }
    if (supportsFastMode(session)) {
      options.push({
        category: "speed",
        currentValue: session.currentSpeed,
        id: "speed",
        name: "Speed",
        options: [
          { name: "Standard", value: "standard" },
          { description: "Prioritized, faster responses", name: "Fast", value: "fast" }
        ]
      })
    }
    return { configOptions: options, modes: PERMISSION_MODES, supportsGoals: true }
  }

  const effortLevelsFor = (session: ClaudeSession): ReadonlyArray<string> =>
    currentClaudeModelFor(session)?.supportedEffortLevels ?? []

  const supportsFastMode = (session: ClaudeSession): boolean =>
    currentClaudeModelFor(session)?.supportsFastMode === true

  const applyClaudeModelFromProvider = (session: ClaudeSession, value: string): void => {
    const sanitized = sanitizeModelValue(value)
    if (session.models.length === 0) {
      session.currentModel = sanitized
      return
    }
    const matched = findKnownModel(session.models, sanitized)
    if (matched !== undefined) {
      session.currentModel = matched.value
      return
    }
    currentClaudeModelFor(session)
  }

  const currentClaudeModelFor = (session: ClaudeSession): ClaudeModel | undefined => {
    if (session.models.length === 0) {
      session.currentModel = sanitizeModelValue(session.currentModel)
      return undefined
    }
    const matched = findKnownModel(session.models, session.currentModel)
    if (matched !== undefined) {
      session.currentModel = matched.value
      return matched
    }
    const fallback = session.models[0]
    if (fallback === undefined) return undefined
    const hadUntrustedModel = session.currentModel.length > 0 && session.currentModel !== "default"
    session.currentModel = fallback.value
    if (hadUntrustedModel) {
      session.currentEffort = highestThinkingLevel(fallback.supportedEffortLevels) ?? "default"
    }
    return fallback
  }

  /// The CLI's default effort for effort-capable models is "high".
  const defaultEffortFor = (levels: ReadonlyArray<string>): string =>
    levels.includes("high") ? "high" : (levels[0] ?? "high")

  const handleFor = (session: ClaudeSession): AgentSessionHandle => ({
    cancel: adapterPromise("cancel", async () => {
      session.interruptRequested = true
      // A held question would block the SDK from processing the interrupt.
      cancelClaudePendingQuestions(session)
      try {
        await session.q.interrupt()
      } catch {
        // The turn may have ended between the request and the interrupt.
      }
    }),
    close: adapterPromise("close", async () => {
      cancelClaudePendingQuestions(session)
      session.input.end()
      session.abort.abort()
    }),
    prompt: (input) =>
      adapterPromise("prompt", async () => {
        const pending = deferred<{ stopReason: string }>()
        session.pendingPrompt = pending
        await ensureTurnStarted(session, "user")
        session.input.push({
          message: { content: claudeContent(normalizePromptInput(input)), role: "user" },
          parent_tool_use_id: null,
          session_id: session.sdkSessionId,
          type: "user"
        })
        return pending.promise
      }),
    setConfigOption: (configId, value) =>
      adapterPromise("setConfigOption", async () => {
        if (configId === "model") {
          await session.q.setModel(value)
          session.currentModel = value
          // Effort validity depends on the model; reset rather than carry an
          // unsupported level over.
          if (!effortLevelsFor(session).includes(session.currentEffort)) {
            session.currentEffort = "default"
          }
          // Same for speed: switch fast mode off rather than carry it to a
          // model that doesn't support it.
          if (session.currentSpeed === "fast" && !supportsFastMode(session)) {
            await session.q.applyFlagSettings({ fastMode: false })
            session.currentSpeed = "standard"
          }
        } else if (configId === "effort") {
          // Cast: the CLI accepts "max" but the SDK Settings type doesn't
          // list it yet.
          await session.q.applyFlagSettings({
            effortLevel: value === "default" ? null : value
          } as Parameters<Query["applyFlagSettings"]>[0])
          session.currentEffort = value
        } else if (configId === "speed") {
          await session.q.applyFlagSettings({ fastMode: value === "fast" })
          session.currentSpeed = value === "fast" ? "fast" : "standard"
        } else {
          throw new Error(`Unknown config option: ${configId}`)
        }
        await session.emit({
          kind: "session.updated",
          payload: {
            configId,
            configOptions: metadataFor(session).configOptions,
            value
          },
          subjectId: session.key
        })
      }),
    setMode: (modeId) =>
      adapterPromise("setMode", async () => {
        await session.q.setPermissionMode(modeId as never)
        await session.emit({
          kind: "session.updated",
          payload: { modeId },
          subjectId: session.key
        })
      }),
    answerQuestion: (questionId, answer) =>
      adapterPromise("answerQuestion", () => answerClaudeQuestion(session, questionId, answer)),
    // Claude Code's goal mode has no SDK API yet — it's driven by the CLI's
    // `/goal` slash command, which the SDK forwards like any prompt. The
    // snapshots HerdMan emits are therefore client-side bookkeeping (no token
    // accounting); the CLI's own reply narrates the goal state in the chat.
    setGoal: (update) =>
      adapterPromise("setGoal", async () => {
        if (update.objective !== undefined) {
          pushGoalCommand(session, `/goal ${update.objective}`)
          const goal: SessionGoal = {
            createdAt: session.currentGoal?.createdAt ?? isoTimestamp(),
            objective: update.objective,
            status: "active",
            timeUsedSeconds: 0,
            tokenBudget: null,
            tokensUsed: 0,
            updatedAt: isoTimestamp()
          }
          session.currentGoal = goal
          await session.emit({
            kind: "session.updated",
            payload: { goal },
            subjectId: session.key
          })
          return goal
        }
        const current = session.currentGoal
        if (current === undefined) {
          throw new Error("No active goal to update")
        }
        const subcommand =
          update.status === "paused" ? "pause" : update.status === "active" ? "resume" : undefined
        if (subcommand === undefined) {
          throw new Error("Claude goal updates support objective, pause, and resume only")
        }
        pushGoalCommand(session, `/goal ${subcommand}`)
        const goal: SessionGoal = { ...current, status: update.status!, updatedAt: isoTimestamp() }
        session.currentGoal = goal
        await session.emit({
          kind: "session.updated",
          payload: { goal },
          subjectId: session.key
        })
        return goal
      }),
    clearGoal: adapterPromise("clearGoal", async () => {
      pushGoalCommand(session, "/goal clear")
      session.currentGoal = undefined
      await session.emit({
        kind: "session.updated",
        payload: { goalCleared: true },
        subjectId: session.key
      })
    })
  })

  return {
    createSession: (definition, cwd, emit): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
      adapterPromise("createSession", async () => {
        const session = await startSession(definition, cwd, emit, undefined)
        return {
          handle: handleFor(session),
          metadata: { sessionId: session.key, ...metadataFor(session) }
        }
      }),
    id: "claude",
    // Native sessions from ~/.claude/projects — workspace suggestions and
    // "import existing chats" for users who ran the CLI before HerdMan.
    listAgentSessions: () => listClaudeAgentSessions(),
    loadSession: (
      definition,
      agentSessionId,
      cwd,
      emit
    ): Effect.Effect<LoadedAgentSession, AgentRuntimeError> =>
      adapterPromise("loadSession", async () => {
        const session = await startSession(definition, cwd, emit, agentSessionId)
        return {
          handle: handleFor(session),
          metadata: { sessionId: session.key, ...metadataFor(session) },
          sessionId: session.key
        }
      }),
    readiness: (definition) => {
      const installed = definition.detectBinaries.some((binary) =>
        environment.executableExists(binary, environment.env)
      )
      return installed
        ? { state: "ready" }
        : { detail: "CLI not found on PATH", state: "unavailable" }
    }
  }
}

// MARK: message pump

const handleMessage = (
  session: ClaudeSession,
  message: SDKMessage,
  readFile: (path: string) => string | undefined
): void => {
  switch (message.type) {
    case "stream_event":
      handleStreamEvent(session, message, readFile)
      break
    case "assistant": {
      const parentId = message.parent_tool_use_id ?? undefined
      if (parentId === undefined) {
        // Remember the SDK's per-message error (overloaded/rate_limit/… or
        // max_output_tokens) so a following error `result` can be classified
        // transient vs permanent, and a truncation can be recovered.
        const assistantError = (message as { error?: unknown }).error
        if (typeof assistantError === "string") {
          session.lastAssistantError = assistantError
        } else {
          // Some transient failures (e.g. a 529 overload) carry no structured
          // error — the CLI renders them as an assistant text message ending on
          // a stop sequence (e.g. "API Error: 529 Overloaded …"). Detect that
          // shape so the turn retries instead of surfacing the error as if it
          // were the answer.
          const apiError = detectApiErrorMessage(message)
          if (apiError !== undefined) {
            session.lastAssistantError = "overloaded"
            session.lastErrorText = apiError
          }
        }
        void ensureTurnStarted(session, session.pendingPrompt === undefined ? "agent" : "user")
      }
      const content = message.message.content
      if (!Array.isArray(content)) break
      const inner = message.message as unknown as Record<string, unknown>
      const messageId = typeof inner.id === "string" ? inner.id : undefined
      // The CLI does not forward subagent stream events, so a subagent's prose
      // exists only here, in its consolidated assistant messages. Emit it
      // tagged with the parent tool call — unless this message DID stream
      // (older CLIs), in which case the chunks are already out and re-emitting
      // would double the text.
      const alreadyStreamed =
        parentId !== undefined &&
        messageId !== undefined &&
        session.subagentMessageIds.get(parentId) === messageId
      for (const block of content) {
        if (!isRecord(block)) continue
        if (block.type === "text" && parentId !== undefined && !alreadyStreamed) {
          const text = String(block.text ?? "")
          if (text.length === 0) continue
          void session.emit({
            kind: "session.output",
            payload: {
              content: { text, type: "text" },
              parentToolCallId: parentId,
              sessionUpdate: "agent_message_chunk",
              ...(messageId === undefined ? {} : { messageId })
            },
            subjectId: session.key
          })
        } else if (block.type === "tool_use") {
          const toolUseId = String(block.id)
          const toolName = String(block.name)
          if (PLAN_TOOLS.has(toolName)) {
            emitPlanUpdate(session, toolName, block.input)
            continue
          }
          // AskUserQuestion surfaces as a blocking question via canUseTool.
          if (HIDDEN_TOOLS.has(toolName)) continue
          const stats = authoritativeStatsFromInput(session, toolName, block.input, readFile)
          void session.emit({
            kind: "session.output",
            payload: {
              // The streamed tool_call may never have existed for subagent
              // tools (no subagent stream events), so this update must carry
              // enough to create the call outright — including its kind.
              kind: toolKind(toolName),
              rawInput: block.input,
              sessionUpdate: "tool_call_update",
              status: "in_progress",
              title: toolTitle(toolName, block.input),
              toolCallId: toolUseId,
              ...(stats === undefined ? {} : { diffStats: stats }),
              ...(parentId === undefined ? {} : { parentToolCallId: parentId })
            },
            subjectId: session.key
          })
        }
      }
      break
    }
    case "user": {
      const content = message.message.content
      if (!Array.isArray(content)) break
      for (const block of content) {
        if (isRecord(block) && block.type === "tool_result") {
          const toolUseId = String(block.tool_use_id)
          session.openToolCalls.delete(toolUseId)
          const accumulator = session.accumulators.get(toolUseId)
          // Plan tools have no tool-call lifecycle on the wire — their result
          // is the plan/plan_document update already emitted.
          if (accumulator !== undefined && HIDDEN_TOOLS.has(accumulator.toolName)) continue
          const doneTitle =
            accumulator !== undefined && accumulator.titledPath !== undefined
              ? finishedToolTitle(accumulator.toolName, accumulator.titledPath)
              : undefined
          // WebSearch's result carries the source links; surface them as
          // resource_link content so the tool card shows a tappable sources
          // list (self-gating: only web-search results parse to sources).
          const sources = block.is_error === true ? [] : webSearchSources(block.content)
          void session.emit({
            kind: "session.output",
            payload: {
              rawOutput: block.content,
              sessionUpdate: "tool_call_update",
              status: block.is_error === true ? "failed" : "completed",
              toolCallId: toolUseId,
              ...(doneTitle === undefined ? {} : { title: doneTitle }),
              ...(sources.length === 0 ? {} : { content: sourcesContent(sources) })
            },
            subjectId: session.key
          })
        }
      }
      break
    }
    case "result":
      handleResult(session, message)
      break
    case "system":
      handleSystemMessage(session, message)
      break
    default:
      break
  }
}

/// Tracks the SDK's background-task lifecycle (`task_*` system messages) so
/// clients can tell "idle" apart from "turn ended, waiting on background
/// work". Every change emits a full replace-on-update snapshot.
const handleSystemMessage = (
  session: ClaudeSession,
  message: Extract<SDKMessage, { type: "system" }>
): void => {
  switch (message.subtype) {
    case "task_started": {
      // Ambient/housekeeping tasks should not make the chat look busy.
      if (message.skip_transcript === true) break
      const terminalKey =
        message.tool_use_id === undefined
          ? undefined
          : session.backgroundShellKeys.get(message.tool_use_id)
      session.backgroundTasks.set(message.task_id, {
        description: message.description,
        id: message.task_id,
        status: "running",
        taskType: message.subagent_type !== undefined ? "subagent" : (message.task_type ?? "task"),
        ...(message.tool_use_id === undefined ? {} : { toolUseId: message.tool_use_id }),
        ...(terminalKey === undefined ? {} : { terminalKey })
      })
      emitBackgroundTasks(session)
      // Retitle the spawning tool call with the task's description — the most
      // reliable source, immune to the Task→Agent tool rename.
      if (message.subagent_type !== undefined && message.tool_use_id !== undefined) {
        void session.emit({
          kind: "session.output",
          payload: {
            kind: "agent",
            sessionUpdate: "tool_call_update",
            title: `Agent: ${message.description}`,
            toolCallId: message.tool_use_id
          },
          subjectId: session.key
        })
      }
      break
    }
    case "task_progress": {
      const entry = session.backgroundTasks.get(message.task_id)
      if (entry === undefined || message.summary === undefined) break
      if (entry.description === message.summary) break
      entry.description = message.summary
      emitBackgroundTasks(session)
      break
    }
    case "task_updated": {
      const entry = session.backgroundTasks.get(message.task_id)
      if (entry === undefined) break
      const status = message.patch.status
      if (status === "completed" || status === "failed" || status === "killed") {
        removeBackgroundTask(session, message.task_id)
      } else {
        if (status !== undefined) entry.status = status
        if (message.patch.description !== undefined) entry.description = message.patch.description
      }
      emitBackgroundTasks(session)
      break
    }
    case "task_notification": {
      if (removeBackgroundTask(session, message.task_id)) {
        emitBackgroundTasks(session)
      }
      break
    }
    default:
      break
  }
}

const emitBackgroundTasks = (session: ClaudeSession): void => {
  void session.emit({
    kind: "session.updated",
    payload: { backgroundTasks: [...session.backgroundTasks.values()] },
    subjectId: session.key
  })
}

const removeBackgroundTask = (session: ClaudeSession, taskId: string): boolean => {
  const entry = session.backgroundTasks.get(taskId)
  if (entry === undefined) return false
  session.backgroundTasks.delete(taskId)
  if (entry.toolUseId !== undefined) {
    session.backgroundShellKeys.delete(entry.toolUseId)
  }
  return true
}

/// PreToolUse rewrite for `Bash(run_in_background: true)`: the command runs
/// under the server's background-terminal wrapper, which tees output to an
/// attachable terminal while stdout/stderr still flow to the SDK unchanged
/// (BashOutput/KillShell keep working). Foreground commands pass through.
const wrapBackgroundBash = (
  session: ClaudeSession,
  toolInput: unknown,
  toolUseID: string,
  wrapCommand: (key: string, command: string) => string
): {
  hookSpecificOutput?: {
    hookEventName: "PreToolUse"
    updatedInput: Record<string, unknown>
  }
} => {
  if (!isRecord(toolInput)) return {}
  if (toolInput.run_in_background !== true || typeof toolInput.command !== "string") {
    return {}
  }
  const key = backgroundTerminalKey(session.key, toolUseID)
  session.backgroundShellKeys.set(toolUseID, key)
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      updatedInput: { ...toolInput, command: wrapCommand(key, toolInput.command) }
    }
  }
}

// MARK: questions

/// Emits the AskUserQuestion as a blocking `question` event and holds the
/// SDK's canUseTool promise open until the human answers. Malformed input
/// falls back to auto-allow so an SDK shape drift can't wedge the turn.
const holdClaudeQuestion = (
  session: ClaudeSession,
  toolInput: Record<string, unknown>
): Promise<ClaudeToolDecision> => {
  const questions = claudeQuestionSpecs(toolInput.questions)
  if (questions.length === 0) {
    return Promise.resolve({ behavior: "allow", updatedInput: toolInput })
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: { questionId, questions, sessionUpdate: "question" },
    subjectId: session.key
  })
  return new Promise((resolve) => {
    session.pendingQuestions.set(questionId, {
      questions,
      resolve,
      respond: (answer) => {
        if (answer.outcome === "cancelled") {
          return { behavior: "deny", message: "User dismissed the question without answering." }
        }
        const entries = answer.answers ?? {}
        const answers: Record<string, string> = {}
        for (const spec of questions) {
          const entry = entries[spec.id]
          if (entry === undefined) continue
          const note = entry.note?.trim() ?? ""
          const labels = entry.answers.join(", ")
          const value =
            labels.length > 0 ? (note.length > 0 ? `${labels} — ${note}` : labels) : note
          if (value.length > 0) {
            answers[spec.question] = value
          }
        }
        return { behavior: "allow", updatedInput: { ...toolInput, answers } }
      }
    })
  })
}

/// Lenient mapping from AskUserQuestion input to the wire QuestionSpec.
/// Ids are positional (`question_<n>`) — the answers map keys back by index.
const claudeQuestionSpecs = (value: unknown): Array<QuestionSpec> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry, index) => {
    if (!isRecord(entry) || typeof entry.question !== "string") return []
    const options = Array.isArray(entry.options)
      ? entry.options.flatMap((option) =>
          isRecord(option) && typeof option.label === "string"
            ? [
                {
                  label: option.label,
                  ...(typeof option.description === "string"
                    ? { description: option.description }
                    : {})
                }
              ]
            : []
        )
      : []
    return [
      {
        allowsOther: true,
        id: `question_${index}`,
        options,
        question: entry.question,
        ...(typeof entry.header === "string" ? { header: entry.header } : {}),
        ...(entry.multiSelect === true ? { multiSelect: true } : {})
      }
    ]
  })
}

/// Folds the human's answer back into the tool input the way the SDK's
/// AskUserQuestion expects: `answers` keyed by the QUESTION TEXT, valued with
/// the chosen label(s). A note supplements a selection (appended after an
/// em-dash) and stands alone as the answer when nothing was selected (the
/// "Other" path). Cancel denies the tool so the model knows the user
/// dismissed the question.
const answerClaudeQuestion = async (
  session: ClaudeSession,
  questionId: string,
  answer: QuestionAnswer
): Promise<void> => {
  const pending = session.pendingQuestions.get(questionId)
  if (pending === undefined) {
    throw new Error(`No pending question: ${questionId}`)
  }
  session.pendingQuestions.delete(questionId)
  pending.resolve(pending.respond(answer))
  await emitClaudeQuestionResolved(
    session,
    questionId,
    answer.outcome === "answered" ? "answered" : "cancelled",
    pending.questions,
    answer.outcome === "answered" ? answer.answers : undefined
  )
}

const emitClaudeQuestionResolved = (
  session: ClaudeSession,
  questionId: string,
  outcome: "answered" | "cancelled",
  questions: ReadonlyArray<QuestionSpec>,
  answers: QuestionAnswer["answers"]
): Promise<void> =>
  session.emit({
    kind: "session.output",
    payload: {
      outcome,
      questionId,
      questions,
      sessionUpdate: "question_resolved",
      ...(answers === undefined ? {} : { answers })
    },
    subjectId: session.key
  })

/// Surfaces a tool-permission check as a blocking Allow/Deny question. Only
/// reached when the CLI's permission mode requires asking (Ask/Plan modes);
/// the bypassPermissions default never invokes canUseTool.
const holdClaudeApproval = (
  session: ClaudeSession,
  toolName: string,
  toolInput: Record<string, unknown>
): Promise<ClaudeToolDecision> => {
  const spec: QuestionSpec = {
    allowsOther: false,
    header: "Permission",
    id: "approval",
    options: [{ label: "Allow" }, { label: "Deny" }],
    question: `Allow ${toolName}?`
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: {
      message: toolTitle(toolName, toolInput),
      questionId,
      questions: [spec],
      sessionUpdate: "question"
    },
    subjectId: session.key
  })
  return new Promise((resolve) => {
    session.pendingQuestions.set(questionId, {
      questions: [spec],
      resolve,
      respond: (answer) =>
        answer.outcome === "answered" && answer.answers?.[spec.id]?.answers[0] === "Allow"
          ? { behavior: "allow", updatedInput: toolInput }
          : { behavior: "deny", message: "User denied permission." }
    })
  })
}

/// The stable question id + option labels that tag Claude's ExitPlanMode
/// approval, so clients recognize a plan approval and answer it. Kept in sync
/// with the Swift client (ACPKit `QuestionRequest`).
const EXIT_PLAN_MODE_QUESTION_ID = "exit_plan_mode"
const IMPLEMENT_PLAN_LABEL = "Implement plan"
const KEEP_PLANNING_LABEL = "Keep planning"

/// ExitPlanMode's approval as a dedicated plan-approval question: the client
/// renders an "implement this plan?" affordance (the plan markdown itself rides
/// a separate `plan_document` update — see emitPlanUpdate). Approving lets the
/// tool through so the model starts implementing; declining keeps it in plan
/// mode, and the deny message nudges it to keep refining rather than stop.
const holdClaudePlanApproval = (
  session: ClaudeSession,
  toolInput: Record<string, unknown>
): Promise<ClaudeToolDecision> => {
  const spec: QuestionSpec = {
    allowsOther: false,
    header: "Plan",
    id: EXIT_PLAN_MODE_QUESTION_ID,
    options: [
      { description: "Start building", label: IMPLEMENT_PLAN_LABEL },
      { description: "Keep refining in plan mode", label: KEEP_PLANNING_LABEL }
    ],
    question: "Ready to implement this plan?"
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: { questionId, questions: [spec], sessionUpdate: "question" },
    subjectId: session.key
  })
  return new Promise((resolve) => {
    session.pendingQuestions.set(questionId, {
      questions: [spec],
      resolve,
      respond: (answer) =>
        answer.outcome === "answered" &&
        answer.answers?.[spec.id]?.answers[0] === IMPLEMENT_PLAN_LABEL
          ? { behavior: "allow", updatedInput: toolInput }
          : {
              behavior: "deny",
              message:
                "The user wants to keep refining the plan. Stay in plan mode and continue planning."
            }
    })
  })
}

/// The SDK stream carries no goal-state messages, so completion is inferred:
/// in non-interactive mode the `/goal` command runs the whole goal loop
/// inside one turn, so that turn's result settles the goal — success marks
/// it complete, an interrupt pauses it (resumable), a failure blocks it.
const settleGoalOnTurnEnd = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" }
): void => {
  const goal = session.currentGoal
  if (goal === undefined || goal.status !== "active") return
  const status = session.interruptRequested
    ? "paused"
    : message.subtype === "success"
      ? "complete"
      : "blocked"
  const settled: SessionGoal = { ...goal, status, updatedAt: isoTimestamp() }
  session.currentGoal = settled
  void session.emit({
    kind: "session.updated",
    payload: { goal: settled },
    subjectId: session.key
  })
}

/// Sends a `/goal` slash command as a user message — the SDK forwards it to
/// the CLI, which executes it exactly like typing it interactively (goal mode
/// has no SDK API yet). The CLI's reply narrates the outcome in the chat.
const pushGoalCommand = (session: ClaudeSession, command: string): void => {
  session.input.push({
    message: { content: [{ text: command, type: "text" }], role: "user" },
    parent_tool_use_id: null,
    session_id: session.sdkSessionId,
    type: "user"
  })
}

/// Interrupts, turn results, and session close invalidate held questions:
/// deny them (the model sees a dismissal) and emit the resolution so clients
/// drop the picker.
const cancelClaudePendingQuestions = (session: ClaudeSession): void => {
  for (const [questionId, pending] of [...session.pendingQuestions]) {
    session.pendingQuestions.delete(questionId)
    pending.resolve(pending.respond({ outcome: "cancelled" }))
    void emitClaudeQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
  }
}

/// Emits the plan-shaped update for a plan tool's authoritative input:
/// TodoWrite → a full-snapshot step checklist (`plan`), ExitPlanMode → the
/// plan-mode plan document (`plan_document`). Malformed input emits nothing.
const emitPlanUpdate = (session: ClaudeSession, toolName: string, input: unknown): void => {
  if (toolName === "TodoWrite") {
    if (!isRecord(input) || !Array.isArray(input.todos)) return
    void session.emit({
      kind: "session.output",
      payload: { entries: planEntriesFromTodos(input.todos), sessionUpdate: "plan" },
      subjectId: session.key
    })
    return
  }
  // ExitPlanMode: the plan markdown is the tool input's `plan` field.
  if (!isRecord(input) || typeof input.plan !== "string" || input.plan.length === 0) return
  void session.emit({
    kind: "session.output",
    payload: { markdown: input.plan, sessionUpdate: "plan_document" },
    subjectId: session.key
  })
}

const handleStreamEvent = (
  session: ClaudeSession,
  message: Extract<SDKMessage, { type: "stream_event" }>,
  readFile: (path: string) => string | undefined
): void => {
  const event = message.event as unknown as Record<string, unknown>
  const parentId = message.parent_tool_use_id ?? undefined
  switch (event.type) {
    case "message_start": {
      const inner = event.message
      const innerId = isRecord(inner) ? String(inner.id ?? "") : undefined
      if (parentId === undefined) {
        session.currentMessageId = innerId
        session.currentMessageTextStreamed = false
        void ensureTurnStarted(session, session.pendingPrompt === undefined ? "agent" : "user")
      } else if (innerId !== undefined && innerId !== "") {
        session.subagentMessageIds.set(parentId, innerId)
      }
      break
    }
    case "content_block_start": {
      const block = event.content_block
      if (isRecord(block) && block.type === "tool_use") {
        // A tool_use block starting after streamed text in the same top-level
        // message proves that text was preamble ("Let me check…"), not the
        // final answer. Retro-tag the span commentary via a zero-length chunk
        // so clients demote it out of the final-answer slot immediately
        // instead of waiting for the next text block after the tool settles.
        if (
          parentId === undefined &&
          session.currentMessageTextStreamed &&
          session.currentMessageId !== undefined &&
          session.currentMessageId !== ""
        ) {
          session.currentMessageTextStreamed = false
          void session.emit({
            kind: "session.output",
            payload: {
              content: { text: "", type: "text" },
              messageId: session.currentMessageId,
              phase: "commentary",
              sessionUpdate: "agent_message_chunk"
            },
            subjectId: session.key
          })
        }
        const toolUseId = String(block.id)
        const toolName = String(block.name)
        session.accumulators.set(toolUseId, {
          json: "",
          lastEmit: 0,
          lastStats: "",
          oldContent: undefined,
          titledPath: undefined,
          toolName
        })
        void ensureTurnStarted(session, session.pendingPrompt === undefined ? "agent" : "user")
        // Plan tools never open a tool call: they surface as plan updates
        // once the authoritative input arrives on the assistant message.
        if (HIDDEN_TOOLS.has(toolName)) break
        session.openToolCalls.add(toolUseId)
        // The model is already generating this call's input — that's work in
        // progress, and for fast tools it's most of the visible lifetime.
        void session.emit({
          kind: "session.output",
          payload: {
            kind: toolKind(toolName),
            sessionUpdate: "tool_call",
            status: "in_progress",
            title: toolName,
            toolCallId: toolUseId,
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
      }
      break
    }
    case "content_block_delta": {
      const delta = event.delta
      if (!isRecord(delta)) break
      if (delta.type === "text_delta") {
        // Subagent prose flows tagged with its parent tool call so clients can
        // nest it under the Task row instead of mixing it into the main thread.
        const messageId =
          parentId === undefined
            ? session.currentMessageId
            : session.subagentMessageIds.get(parentId)
        if (parentId === undefined && String(delta.text ?? "").length > 0) {
          session.currentMessageTextStreamed = true
        }
        void session.emit({
          kind: "session.output",
          payload: {
            content: { text: String(delta.text ?? ""), type: "text" },
            sessionUpdate: "agent_message_chunk",
            ...(messageId === undefined ? {} : { messageId }),
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
      } else if (delta.type === "thinking_delta") {
        void session.emit({
          kind: "session.output",
          payload: {
            content: { text: String(delta.thinking ?? ""), type: "text" },
            sessionUpdate: "agent_thought_chunk",
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
      } else if (delta.type === "input_json_delta") {
        const toolUseId = String(event.index !== undefined ? findAccumulatorId(session, event) : "")
        const accumulator = session.accumulators.get(toolUseId)
        if (accumulator !== undefined) {
          accumulator.json += String(delta.partial_json ?? "")
          maybeEmitStreamStats(session, toolUseId, accumulator, readFile, false)
        }
      }
      break
    }
    case "content_block_stop": {
      const toolUseId = findAccumulatorId(session, event)
      const accumulator = session.accumulators.get(toolUseId)
      if (accumulator !== undefined) {
        maybeEmitStreamStats(session, toolUseId, accumulator, readFile, true)
      }
      break
    }
    default:
      break
  }
}

/// The Anthropic stream identifies blocks by index, not id. Content blocks
/// stream strictly sequentially per message, so the accumulator opened last
/// is the one receiving deltas.
const findAccumulatorId = (session: ClaudeSession, _event: Record<string, unknown>): string => {
  let lastKey = ""
  for (const key of session.accumulators.keys()) {
    lastKey = key
  }
  return lastKey
}

/// One resolution of an SDK `result`: either keep the same turn alive and
/// recover (truncation continuation or transient retry), or end it — with an
/// optional human `stopDetail` the client renders when the ending isn't clean.
/// Extracts the CLI's error text when a transient failure arrived as a plain
/// assistant message ending on a stop sequence (e.g. "API Error: 529 Overloaded
/// …"). Returns the trimmed text, or undefined when it isn't that shape.
const detectApiErrorMessage = (message: SDKMessage & { type: "assistant" }): string | undefined => {
  const inner = message.message as { stop_reason?: unknown; content?: unknown }
  if (inner.stop_reason !== "stop_sequence") return undefined
  const content = inner.content
  if (!Array.isArray(content)) return undefined
  const text = content
    .filter((block): block is Record<string, unknown> => isRecord(block) && block.type === "text")
    .map((block) => (typeof block.text === "string" ? block.text : ""))
    .join("")
    .trim()
  return API_ERROR_TEXT.test(text) ? text : undefined
}

type TurnResolution =
  | { readonly kind: "continue" }
  | { readonly kind: "retry"; readonly delayMs: number; readonly attempt: number }
  | { readonly kind: "end"; readonly stopReason: string; readonly stopDetail?: string | undefined }

/// Classifies an SDK `result`:
///  - output-token truncation (`max_tokens`/`max_output_tokens`) or the
///    turn-count limit → silent `continue` (bounded by MAX_TRUNCATION_CONTINUATIONS);
///  - a transient API failure (`error_during_execution`, a transient assistant
///    `error`, or a detected "API Error: 5xx" text) → visible `retry` with
///    backoff (bounded by MAX_TRANSIENT_RETRIES);
///  - otherwise `end`, surfacing a reason for a refusal, permanent error, hit
///    limit, or exhausted retries.
const classifyResult = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" }
): TurnResolution => {
  if (session.interruptRequested) return { kind: "end", stopReason: "cancelled" }

  const subtype = message.subtype
  const stopReasonRaw = typeof message.stop_reason === "string" ? message.stop_reason : ""
  const lastError = session.lastAssistantError ?? ""

  const truncated =
    (subtype === "success" && TRUNCATION_STOP_REASONS.has(stopReasonRaw)) ||
    lastError === "max_output_tokens"
  const turnLimit = subtype === "error_max_turns"
  const permanentError = subtype !== "success" && PERMANENT_ASSISTANT_ERRORS.has(lastError)
  // Transient covers an error_during_execution result, a transient assistant
  // error, or a 529-style error that arrived as text — regardless of the result
  // subtype (a 529 can surface as a `success` with the error baked into text).
  const transient =
    !permanentError &&
    (subtype === "error_during_execution" || TRANSIENT_ASSISTANT_ERRORS.has(lastError))

  // Silent continuation: the response was truncated (or hit the turn limit) and
  // legitimately has more to say. No delay, no visible status.
  if ((truncated || turnLimit) && session.truncationCount < MAX_TRUNCATION_CONTINUATIONS) {
    return { kind: "continue" }
  }
  // Visible retry: a transient API failure, backed off and shown to the user.
  if (transient && session.transientRetries < MAX_TRANSIENT_RETRIES) {
    return {
      kind: "retry",
      delayMs: recoveryBackoffMs(session.transientRetries),
      attempt: session.transientRetries + 1
    }
  }

  // Terminal. A genuinely clean success ends quietly, noting only a refusal or a
  // truncation we gave up on.
  if (subtype === "success" && !transient) {
    const stopDetail =
      stopReasonRaw === "refusal"
        ? "Claude declined to respond."
        : truncated
          ? "Response hit the output-token limit."
          : undefined
    return { kind: "end", stopReason: "end_turn", stopDetail }
  }
  // An error, or a transient failure whose retries are spent: surface the real
  // API error text when we have it, else a described reason.
  return {
    kind: "end",
    stopReason: subtype === "error_max_turns" ? "max_turn_requests" : "end_turn",
    stopDetail:
      transient && session.lastErrorText !== undefined
        ? session.lastErrorText
        : describeStop(subtype, lastError)
  }
}

/// A short, human-readable reason for a turn that ended abnormally, rendered
/// under the turn in the transcript (there is no clean-completion string).
const describeStop = (subtype: string, lastError: string): string => {
  switch (lastError) {
    case "overloaded":
      return "The Claude API was overloaded."
    case "rate_limit":
      return "Rate limited by the Claude API."
    case "server_error":
      return "The Claude API returned a server error."
    case "authentication_failed":
      return "Claude authentication failed."
    case "oauth_org_not_allowed":
      return "This organization isn't allowed to use this model."
    case "billing_error":
      return "A billing error stopped the turn."
    case "invalid_request":
      return "The request was rejected as invalid."
    case "model_not_found":
      return "The selected model is unavailable."
    default:
      break
  }
  switch (subtype) {
    case "error_max_turns":
      return "Reached the maximum number of turns."
    case "error_max_budget_usd":
      return "Reached the usage budget."
    case "error_max_structured_output_retries":
      return "Couldn't produce valid structured output."
    default:
      return "Claude Code ended the turn unexpectedly."
  }
}

const pushContinuePrompt = (session: ClaudeSession): void => {
  session.input.push({
    message: { content: CONTINUE_PROMPT, role: "user" },
    parent_tool_use_id: null,
    session_id: session.sdkSessionId,
    type: "user"
  })
}

/// Resumes the live turn after a recoverable stop by pushing a continue nudge.
/// A positive delay (transient backoff) is scheduled; the callback bails if the
/// session was closed while waiting, so a timer can never resume a dead session.
const scheduleRecovery = (session: ClaudeSession, delayMs: number): void => {
  if (delayMs <= 0) {
    pushContinuePrompt(session)
    return
  }
  setTimeout(() => {
    if (session.abort.signal.aborted || !session.turnActive) return
    pushContinuePrompt(session)
  }, delayMs)
}

/// Emits a visible "retrying" status so the client can show "Retrying… (n/3)"
/// while a transient failure is being retried. The client clears it when the
/// next output arrives or the turn ends.
const emitRetrying = (session: ClaudeSession, attempt: number, of: number): void => {
  void session.emit({
    kind: "session.updated",
    payload: { retrying: { attempt, of }, turnId: session.turnId },
    subjectId: session.key
  })
}

/// Dev-only turn-end trace (gated on HERDMAN_DEBUG). The provider has no logger;
/// this matches the plain-console style used in apps/server/src/main.ts. This is
/// how we learn the real dominant stop reason without shipping any UI noise.
const logTurnEnd = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" },
  resolution: TurnResolution
): void => {
  const terminal = (message as { terminal_reason?: unknown }).terminal_reason
  const outcome =
    resolution.kind === "continue"
      ? "continue"
      : resolution.kind === "retry"
        ? `retry#${resolution.attempt}(${resolution.delayMs}ms)`
        : `end/${resolution.stopReason}${resolution.stopDetail === undefined ? "" : ` — ${resolution.stopDetail}`}`
  console.error(
    `[claude] turn-end subtype=${message.subtype} stop_reason=${message.stop_reason ?? "-"} ` +
      `terminal=${typeof terminal === "string" ? terminal : "-"} lastError=${session.lastAssistantError ?? "-"} ` +
      `trunc=${session.truncationCount} retries=${session.transientRetries} -> ${outcome}`
  )
}

const handleResult = (session: ClaudeSession, message: SDKMessage & { type: "result" }): void => {
  const resolution = classifyResult(session, message)
  if (process.env.HERDMAN_DEBUG !== undefined) logTurnEnd(session, message, resolution)
  // Each `result` is classified on the assistant error seen since the previous
  // one; consume it so a stale error can't misclassify a later leg.
  session.lastAssistantError = undefined

  if (resolution.kind === "continue") {
    // Output truncated — resume the same turn immediately and invisibly; the
    // model just had more to say.
    session.truncationCount += 1
    scheduleRecovery(session, 0)
    return
  }
  if (resolution.kind === "retry") {
    // Transient API failure — show "Retrying…", back off, then resume. The turn
    // stays alive; turnId/pendingPrompt are untouched.
    session.transientRetries += 1
    emitRetrying(session, resolution.attempt, MAX_TRANSIENT_RETRIES)
    scheduleRecovery(session, resolution.delayMs)
    return
  }

  // Terminal. A turn that ends with questions still open (interrupt, failure)
  // invalidates them — clients must not keep showing the picker.
  session.lastErrorText = undefined
  cancelClaudePendingQuestions(session)
  settleGoalOnTurnEnd(session, message)
  finishActiveTurn(session, resolution.stopReason, resolution.stopDetail)
}

/// Ends the in-flight turn: settles any tool calls that never got a result,
/// clears per-turn accumulators, emits `turnState: ended`, and resolves the
/// awaiting prompt. The single place `turnActive` is cleared. Driven by an SDK
/// `result` (via `handleResult`) and, defensively, by the pump when the SDK
/// stream dies mid-turn — so a wedged stream can never leave the client showing
/// "working" forever.
const finishActiveTurn = (
  session: ClaudeSession,
  stopReason: string,
  stopDetail?: string | undefined
): void => {
  // Anything still open never got a tool_result (interrupt/failure/stream end).
  for (const toolUseId of [...session.openToolCalls]) {
    session.openToolCalls.delete(toolUseId)
    void session.emit({
      kind: "session.output",
      payload: {
        sessionUpdate: "tool_call_update",
        status: session.interruptRequested ? "cancelled" : "failed",
        toolCallId: toolUseId
      },
      subjectId: session.key
    })
  }
  session.accumulators.clear()
  session.subagentMessageIds.clear()

  const ended: RuntimeEvent = {
    kind: "session.updated",
    payload: {
      initiatedBy: session.initiatedBy,
      stopReason,
      // Only present when the turn ended abnormally (error / limit / refusal /
      // truncation we gave up on); the client renders it as a per-turn reason.
      ...(stopDetail === undefined ? {} : { stopDetail }),
      turnId: session.turnId,
      turnState: "ended"
    },
    subjectId: session.key
  }
  const pending = session.pendingPrompt
  session.pendingPrompt = undefined
  session.turnActive = false
  session.interruptRequested = false
  void session.emit(ended).then(() => {
    pending?.resolve({ stopReason })
  })
}

const ensureTurnStarted = (
  session: ClaudeSession,
  initiatedBy: "user" | "agent"
): Promise<void> => {
  if (session.turnActive) return Promise.resolve()
  session.turnActive = true
  session.turnId = randomUUID()
  session.initiatedBy = initiatedBy
  // Fresh turn: reset the recovery counters (auto-recoveries keep `turnActive`
  // true, so this never fires mid-recovery) and drop any stale error state.
  session.truncationCount = 0
  session.transientRetries = 0
  session.lastAssistantError = undefined
  session.lastErrorText = undefined
  return session.emit({
    kind: "session.updated",
    payload: { initiatedBy, turnId: session.turnId, turnState: "started" },
    subjectId: session.key
  })
}

// MARK: diff stats

const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"])

const maybeEmitStreamStats = (
  session: ClaudeSession,
  toolUseId: string,
  accumulator: ToolInputAccumulator,
  readFile: (path: string) => string | undefined,
  force: boolean
): void => {
  if (!EDIT_TOOLS.has(accumulator.toolName)) return
  const now = Date.now()
  if (!force && now - accumulator.lastEmit < STREAM_STATS_INTERVAL_MS) return
  const stats = streamingStats(session, accumulator, readFile)
  if (stats === undefined) return
  const fingerprint = JSON.stringify(stats)
  if (fingerprint === accumulator.lastStats) return
  accumulator.lastEmit = now
  accumulator.lastStats = fingerprint
  const path = stats[0]?.path
  const title =
    path !== undefined && accumulator.titledPath !== path
      ? activeToolTitle(accumulator.toolName, path)
      : undefined
  if (path !== undefined) {
    accumulator.titledPath = path
  }
  void session.emit({
    kind: "session.output",
    payload: {
      diffStats: stats,
      sessionUpdate: "tool_call_update",
      status: "in_progress",
      toolCallId: toolUseId,
      ...(title === undefined ? {} : { title })
    },
    subjectId: session.key
  })
}

/// Running estimate computed from the partially streamed tool input. Counts
/// only ever grow as the strings stream in; the consolidated input and the
/// PostToolUse hook later replace them with authoritative numbers.
const streamingStats = (
  session: ClaudeSession,
  accumulator: ToolInputAccumulator,
  readFile: (path: string) => string | undefined
): Array<DiffStat> | undefined => {
  const path = extractStringField(accumulator.json, "file_path")
  if (path === undefined || path.length === 0) return undefined
  switch (accumulator.toolName) {
    case "Edit": {
      const oldString = extractStringField(accumulator.json, "old_string") ?? ""
      const newString = extractStringField(accumulator.json, "new_string") ?? ""
      return [{ added: lineCount(newString), path, removed: lineCount(oldString) }]
    }
    case "Write": {
      if (accumulator.oldContent === undefined) {
        accumulator.oldContent = readFile(absolutePath(session.cwd, path)) ?? null
      }
      const content = extractStringField(accumulator.json, "content") ?? ""
      return [
        {
          added: lineCount(content),
          path,
          removed: accumulator.oldContent === null ? 0 : lineCount(accumulator.oldContent)
        }
      ]
    }
    case "MultiEdit": {
      const oldStrings = extractAllStringFields(accumulator.json, "old_string")
      const newStrings = extractAllStringFields(accumulator.json, "new_string")
      return [
        {
          added: newStrings.reduce((total, text) => total + lineCount(text), 0),
          path,
          removed: oldStrings.reduce((total, text) => total + lineCount(text), 0)
        }
      ]
    }
    default:
      return undefined
  }
}

/// Authoritative stats from the consolidated (fully parsed) tool input.
const authoritativeStatsFromInput = (
  session: ClaudeSession,
  toolName: string,
  input: unknown,
  readFile: (path: string) => string | undefined
): Array<DiffStat> | undefined => {
  if (!EDIT_TOOLS.has(toolName) || !isRecord(input)) return undefined
  const path = typeof input.file_path === "string" ? input.file_path : undefined
  if (path === undefined) return undefined
  switch (toolName) {
    case "Edit": {
      const oldString = typeof input.old_string === "string" ? input.old_string : ""
      const newString = typeof input.new_string === "string" ? input.new_string : ""
      return [diffStatsFromTexts(path, oldString, newString)]
    }
    case "Write": {
      const content = typeof input.content === "string" ? input.content : ""
      const oldContent = readFile(absolutePath(session.cwd, path))
      return [diffStatsFromTexts(path, oldContent, content)]
    }
    case "MultiEdit": {
      const edits = Array.isArray(input.edits) ? input.edits : []
      let added = 0
      let removed = 0
      for (const edit of edits) {
        if (!isRecord(edit)) continue
        const stats = diffStatsFromTexts(
          path,
          typeof edit.old_string === "string" ? edit.old_string : "",
          typeof edit.new_string === "string" ? edit.new_string : ""
        )
        added += stats.added
        removed += stats.removed
      }
      return [{ added, path, removed }]
    }
    default:
      return undefined
  }
}

/// PostToolUse delivers the on-disk truth (structuredPatch reflects
/// replace_all and the file's actual state); emit the final stats plus a
/// renderable diff content block.
const emitAuthoritativeDiff = (
  session: ClaudeSession,
  hookInput: {
    tool_name: string
    tool_input: unknown
    tool_response: unknown
    tool_use_id: string
  },
  readFile: (path: string) => string | undefined
): void => {
  if (!EDIT_TOOLS.has(hookInput.tool_name)) return
  const input = isRecord(hookInput.tool_input) ? hookInput.tool_input : {}
  const path = typeof input.file_path === "string" ? input.file_path : undefined
  if (path === undefined) return

  const response = isRecord(hookInput.tool_response) ? hookInput.tool_response : {}
  let stats: DiffStat | undefined
  if (Array.isArray(response.structuredPatch)) {
    let added = 0
    let removed = 0
    for (const hunk of response.structuredPatch) {
      if (!isRecord(hunk) || !Array.isArray(hunk.lines)) continue
      for (const line of hunk.lines) {
        if (typeof line !== "string") continue
        if (line.startsWith("+")) added += 1
        else if (line.startsWith("-")) removed += 1
      }
    }
    stats = { added, path, removed }
  }

  const diffBlock = diffContentBlock(session, hookInput.tool_name, input, response, path, readFile)
  // A file creation's tool_response carries an empty structuredPatch (there
  // was nothing to patch — the whole file is new), which would report an
  // authoritative +0 −0 that beats the client's content-derived totals. When
  // the diff content shows a real change, recompute the stats from the texts.
  if (
    stats !== undefined &&
    stats.added === 0 &&
    stats.removed === 0 &&
    diffBlock !== undefined &&
    (diffBlock.oldText ?? "") !== diffBlock.newText
  ) {
    stats = diffStatsFromTexts(path, diffBlock.oldText, diffBlock.newText)
  }
  if (stats === undefined && diffBlock === undefined) return
  void session.emit({
    kind: "session.output",
    payload: {
      sessionUpdate: "tool_call_update",
      toolCallId: hookInput.tool_use_id,
      ...(stats === undefined ? {} : { diffStats: [stats] }),
      ...(diffBlock === undefined ? {} : { content: [diffBlock] }),
      ...(stats === undefined && diffBlock !== undefined
        ? { diffStats: [diffStatsFromTexts(path, diffBlock.oldText, diffBlock.newText)] }
        : {})
    },
    subjectId: session.key
  })
}

const diffContentBlock = (
  session: ClaudeSession,
  toolName: string,
  input: Record<string, unknown>,
  response: Record<string, unknown>,
  path: string,
  readFile: (path: string) => string | undefined
): { type: "diff"; path: string; oldText: string | null; newText: string } | undefined => {
  switch (toolName) {
    case "Edit": {
      const oldString = typeof input.old_string === "string" ? input.old_string : null
      const newString = typeof input.new_string === "string" ? input.new_string : ""
      return { newText: newString, oldText: oldString, path, type: "diff" }
    }
    case "Write": {
      const content = typeof input.content === "string" ? input.content : ""
      const original =
        typeof response.originalFile === "string"
          ? response.originalFile
          : readFile(absolutePath(session.cwd, path)) === content
            ? null
            : null
      return { newText: content, oldText: original, path, type: "diff" }
    }
    default:
      return undefined
  }
}

// MARK: helpers

const absolutePath = (cwd: string, path: string): string =>
  isAbsolute(path) ? path : resolve(cwd, path)

const toolKind = (toolName: string): string => {
  switch (toolName) {
    case "Read":
      return "read"
    case "Edit":
    case "Write":
    case "MultiEdit":
    case "NotebookEdit":
      return "edit"
    case "Bash":
    case "BashOutput":
    case "KillShell":
      return "execute"
    case "Grep":
    case "Glob":
      return "search"
    case "WebFetch":
      return "fetch"
    // Not ACP vocabulary — HerdMan's own extension so clients can phrase web
    // searches as searches ("Searched the web") instead of fetches.
    case "WebSearch":
      return "web_search"
    case "TodoWrite":
      return "think"
    // The subagent-spawn tool: "Task" historically, "Agent" in newer CLIs.
    case "Task":
    case "Agent":
      return "agent"
    default:
      return "other"
  }
}

const fileNameOf = (path: string): string => path.split("/").at(-1) ?? path

/// Present-tense title while a file tool is running.
const activeToolTitle = (toolName: string, path: string): string | undefined => {
  const file = fileNameOf(path)
  switch (toolName) {
    case "Edit":
    case "MultiEdit":
      return `Editing ${file}`
    case "Write":
      return `Writing ${file}`
    default:
      return undefined
  }
}

/// Past-tense title once the tool has finished.
const finishedToolTitle = (toolName: string, path: string): string | undefined => {
  const file = fileNameOf(path)
  switch (toolName) {
    case "Edit":
    case "MultiEdit":
      return `Edited ${file}`
    case "Write":
      return `Wrote ${file}`
    default:
      return undefined
  }
}

const toolTitle = (toolName: string, input: unknown): string => {
  if (isRecord(input)) {
    if (typeof input.file_path === "string") {
      const file = input.file_path.split("/").at(-1) ?? input.file_path
      switch (toolName) {
        case "Read":
          return `Read ${file}`
        case "Edit":
        case "MultiEdit":
          return `Edited ${file}`
        case "Write":
          return `Wrote ${file}`
        default:
          break
      }
    }
    if (toolName === "Bash" && typeof input.command === "string") {
      return `Ran ${input.command.split("\n")[0]?.slice(0, 80) ?? ""}`
    }
    if (toolName === "WebSearch" && typeof input.query === "string") {
      return `Searched for ${input.query}`
    }
    if (toolName === "WebFetch" && typeof input.url === "string") {
      return `Fetched ${input.url}`
    }
    if (typeof input.pattern === "string") {
      return `Searched for ${input.pattern}`
    }
    if ((toolName === "Task" || toolName === "Agent") && typeof input.description === "string") {
      return `Agent: ${input.description}`
    }
  }
  return toolName
}

/// A WebSearch result source (a search hit's title + URL).
export interface WebSearchSource {
  readonly title: string
  readonly url: string
}

/// Extracts the sources from a Claude WebSearch tool_result. The CLI returns a
/// string of the shape:
///   Web search results for query: "…"
///   Links: [{"title":"…","url":"…"}, …]
///   …model commentary…
/// The `Links:` array is the only structured payload; we parse it into the
/// hits so the client can render a sources list. Returns `[]` for anything
/// that isn't a web-search result, so non-search tool results never sprout a
/// bogus sources card.
export const webSearchSources = (content: unknown): Array<WebSearchSource> => {
  const text =
    typeof content === "string"
      ? content
      : Array.isArray(content)
        ? content
            .map((block) => (isRecord(block) && typeof block.text === "string" ? block.text : ""))
            .join("")
        : ""
  if (!text.includes("Web search results for query:")) return []
  const marker = text.indexOf("Links:")
  if (marker === -1) return []
  const start = text.indexOf("[", marker)
  if (start === -1) return []
  // Balanced-bracket scan that ignores brackets inside JSON strings, so the
  // array is isolated even when a title contains "[" or "]".
  let depth = 0
  let inString = false
  let escaped = false
  let end = -1
  for (let index = start; index < text.length; index += 1) {
    const char = text[index]
    if (escaped) {
      escaped = false
      continue
    }
    if (char === "\\") {
      escaped = true
      continue
    }
    if (char === '"') {
      inString = !inString
      continue
    }
    if (inString) continue
    if (char === "[") depth += 1
    else if (char === "]") {
      depth -= 1
      if (depth === 0) {
        end = index
        break
      }
    }
  }
  if (end === -1) return []
  let parsed: unknown
  try {
    parsed = JSON.parse(text.slice(start, end + 1))
  } catch {
    return []
  }
  if (!Array.isArray(parsed)) return []
  const sources: Array<WebSearchSource> = []
  for (const hit of parsed) {
    if (isRecord(hit) && typeof hit.title === "string" && typeof hit.url === "string") {
      sources.push({ title: hit.title, url: hit.url })
    }
  }
  return sources
}

/// Maps parsed web-search sources to ACP `resource_link` tool-call content so
/// the client renders each as a titled, tappable link. Capped so a pathological
/// result can't flood the card.
const sourcesContent = (sources: Array<WebSearchSource>): Array<Record<string, unknown>> =>
  sources.slice(0, 20).map((source) => ({
    content: { name: source.title, title: source.title, type: "resource_link", uri: source.url },
    type: "content"
  }))

/// Extracts a JSON string field's (possibly still-streaming) value from a
/// partial JSON buffer without a full parser: finds `"field":"` and decodes
/// escapes until the closing quote or the end of the buffer.
export const extractStringField = (json: string, field: string): string | undefined => {
  const key = `"${field}"`
  let index = json.indexOf(key)
  if (index === -1) return undefined
  index += key.length
  while (index < json.length && (json[index] === " " || json[index] === ":")) index += 1
  if (json[index] !== '"') return undefined
  index += 1
  return decodeJsonString(json, index).value
}

/// Extracts every occurrence of a string field (for MultiEdit's edits array).
export const extractAllStringFields = (json: string, field: string): Array<string> => {
  const key = `"${field}"`
  const values: Array<string> = []
  let cursor = 0
  while (true) {
    let index = json.indexOf(key, cursor)
    if (index === -1) return values
    index += key.length
    while (index < json.length && (json[index] === " " || json[index] === ":")) index += 1
    if (json[index] !== '"') {
      cursor = index
      continue
    }
    index += 1
    const decoded = decodeJsonString(json, index)
    values.push(decoded.value)
    cursor = decoded.end
  }
}

const decodeJsonString = (json: string, start: number): { value: string; end: number } => {
  let out = ""
  let index = start
  while (index < json.length) {
    const ch = json[index]
    if (ch === "\\") {
      const next = json[index + 1]
      if (next === undefined) break
      switch (next) {
        case "n":
          out += "\n"
          break
        case "t":
          out += "\t"
          break
        case "r":
          out += "\r"
          break
        case '"':
          out += '"'
          break
        case "\\":
          out += "\\"
          break
        case "/":
          out += "/"
          break
        case "u": {
          const hex = json.slice(index + 2, index + 6)
          if (hex.length === 4 && /^[0-9a-fA-F]{4}$/.test(hex)) {
            out += String.fromCharCode(Number.parseInt(hex, 16))
            index += 4
          }
          break
        }
        default:
          out += next
      }
      index += 2
      continue
    }
    if (ch === '"') {
      return { end: index + 1, value: out }
    }
    out += ch
    index += 1
  }
  return { end: index, value: out }
}

const compareVersions = (left: string, right: string): number => {
  const leftParts = left.split(".").map((part) => Number.parseInt(part, 10) || 0)
  const rightParts = right.split(".").map((part) => Number.parseInt(part, 10) || 0)
  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0)
    if (difference !== 0) return difference < 0 ? -1 : 1
  }
  return 0
}

/* v8 ignore start -- exercised against a live claude binary, not in unit tests. */
const runClaudeVersion = (claudePath: string): Promise<string> =>
  new Promise((resolvePromise, rejectPromise) => {
    execFile(claudePath, ["--version"], { timeout: 5000 }, (error, stdout) => {
      if (error !== null) {
        rejectPromise(new Error(`claude --version failed: ${error.message}`))
        return
      }
      const match = /(\d+\.\d+\.\d+)/.exec(stdout)
      if (match?.[1] === undefined) {
        rejectPromise(new Error(`Could not parse claude version from: ${stdout.trim()}`))
        return
      }
      resolvePromise(match[1])
    })
  })
/* v8 ignore stop */

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
