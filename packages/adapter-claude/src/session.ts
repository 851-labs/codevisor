import type {
  getSessionInfo as sdkGetSessionInfo,
  Options as ClaudeOptions,
  Query,
  SDKMessage,
  SDKUserMessage
} from "@anthropic-ai/claude-agent-sdk"
import type { QuestionSpec, SessionGoal } from "@codevisor/api"
import type {
  CancelResult,
  PromptInput,
  QuestionAnswer,
  RuntimeEmit
} from "@codevisor/agent-runtime"
import type { Deferred } from "./internal.js"

/// A prompt accepted while another turn was still active. It is NOT bound to
/// `pendingPrompt` (the active turn's terminal event would resolve it before
/// the prompt ever ran) and its message is NOT pushed to the SDK yet (the SDK
/// would fold it into the live turn). It dispatches as its own user turn when
/// the active turn finishes.
export interface DeferredClaudePrompt {
  readonly input: string | PromptInput
  readonly pending: Deferred<{ stopReason: string }>
}

export interface ClaudeTaskEntry {
  readonly subject: string
  readonly status: "pending" | "in_progress" | "completed"
  readonly activeForm?: string
  readonly description?: string
}

export type ClaudeTaskState = Map<string, ClaudeTaskEntry>

export interface ClaudeTaskToolUse {
  readonly name: string
  readonly input: unknown
}

export interface ClaudeModel {
  readonly value: string
  readonly name: string
  readonly supportedEffortLevels: ReadonlyArray<string>
  readonly supportsFastMode: boolean
}

export type ClaudeQueryFn = (input: {
  prompt: AsyncIterable<SDKUserMessage>
  options: ClaudeOptions
}) => Query

/// Push-based AsyncIterable used as the SDK's streaming prompt input; keeping
/// it open keeps the Claude process alive across turns, which is what lets
/// between-turn/background output flow.
export class InputQueue implements AsyncIterable<SDKUserMessage> {
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

/// Accumulates the streamed partial JSON of one tool_use input so edit tools
/// can report running added/removed line counts while the model is typing.
export interface ToolInputAccumulator {
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
export interface BackgroundTaskEntry {
  readonly id: string
  description: string
  status: string
  readonly taskType: string
  readonly toolUseId?: string
  /// Set when the task's process streams through a server-owned terminal
  /// (background Bash rewritten by the PreToolUse hook).
  readonly terminalKey?: string
}

export type ClaudeToolDecision =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string }

/// One blocking canUseTool ask (AskUserQuestion or a permission approval)
/// awaiting the human's answer. `resolve` settles the SDK's canUseTool
/// promise; `respond` builds the source-specific decision from the wire
/// answer (including dismissals).
export interface PendingClaudeQuestion {
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly resolve: (result: ClaudeToolDecision) => void
  readonly respond: (answer: QuestionAnswer) => ClaudeToolDecision
}

export interface ClaudeSession {
  /// The id the runtime and server know this session by (== SDK session id
  /// for new sessions; the requested id for resumed ones).
  readonly key: string
  readonly sdkSessionId: string
  readonly cwd: string
  readonly q: Query
  readonly input: InputQueue
  readonly emit: RuntimeEmit
  readonly getSessionInfo: typeof sdkGetSessionInfo
  readonly abort: AbortController
  lastHarnessTitle: string | undefined
  turnActive: boolean
  turnId: string
  initiatedBy: "user" | "agent"
  pendingPrompt: Deferred<{ stopReason: string }> | undefined
  /// Prompts that arrived while a turn (typically an agent-initiated
  /// task-notification follow-up) was active. Drained FIFO by
  /// `finishActiveTurn`, each as its own user-initiated turn.
  readonly deferredPrompts: Array<DeferredClaudePrompt>
  /// Resolves only after the current turn's terminal event has passed through
  /// the ordered runtime sink. Retained after turnActive clears so a racing
  /// cancel can still wait for durable completion.
  turnCompletion: Deferred<void> | undefined
  cancelInFlight: Promise<CancelResult> | undefined
  retired: boolean
  streamEnded: boolean
  /// Slash commands injected on the user's behalf (currently `/goal`) do not
  /// have a blocking `pendingPrompt`, but their turns still belong to the
  /// user's attention epoch rather than to autonomous background activity.
  pendingUserCommands: number
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
  /// Claude's own user-facing explanation for a genuinely exhausted usage
  /// allowance (for example "You've hit your limit · resets 8pm"). Unlike a
  /// temporary 429, this is terminal and must never trigger an outer retry.
  lastUsageLimitText: string | undefined
  /// Latest claude.ai subscription-limit state observed since the previous
  /// result. A rejected state is a structured fallback when the result omits
  /// Claude's richer limit text.
  latestRateLimitInfo:
    | Extract<SDKMessage, { type: "rate_limit_event" }>["rate_limit_info"]
    | undefined
  /// Context occupancy from the latest top-level assistant request. Claude's
  /// result usage is cumulative; the per-message input + cache buckets are the
  /// authoritative current-context count.
  latestContextUsage: { model: string | undefined; used: number } | undefined
  /// Stable identity for the latest context-compaction lifecycle. Claude's
  /// status messages do not provide one, so the provider assigns it when
  /// compaction starts and reuses it for the matching result.
  activeContextCompactionId: string | undefined
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
  /// Authoritative Task* inputs keyed by tool_use id, retained until the
  /// matching result confirms whether the mutation succeeded.
  readonly taskToolUses: Map<string, ClaudeTaskToolUse>
  /// Cross-turn checklist state built from Task* mutations and task hooks.
  readonly tasks: ClaudeTaskState
  /// Current message id per streaming subagent, keyed by the subagent's
  /// parent tool_use id — keeps subagent text spans stable across replay
  /// without touching the main agent's `currentMessageId`.
  readonly subagentMessageIds: Map<string, string>
  /// Cross-turn: background tasks legitimately outlive the turn that spawned
  /// them, so this is never cleared at turn end.
  readonly backgroundTasks: Map<string, BackgroundTaskEntry>
  /// SDK housekeeping tasks marked `skip_transcript` are absent from the UI
  /// even when the authoritative level snapshot includes their ids.
  readonly hiddenBackgroundTaskIds: Set<string>
  /// tool_use id → server terminal key, recorded when the PreToolUse hook
  /// rewrites a background Bash command; consumed by `task_started` to stamp
  /// the task with its attachable terminal.
  readonly backgroundShellKeys: Map<string, string>
  /// question id → held AskUserQuestion canUseTool promise.
  readonly pendingQuestions: Map<string, PendingClaudeQuestion>
  /// Client-side goal snapshot. Claude Code's goal mode is driven through the
  /// CLI's `/goal` slash command (the SDK has no goal API yet), so Codevisor
  /// tracks the last state it set — the CLI gives no structured feedback.
  currentGoal: SessionGoal | undefined
}
