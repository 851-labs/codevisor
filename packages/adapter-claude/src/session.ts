import type {
  getSessionInfo as sdkGetSessionInfo,
  Options as ClaudeOptions,
  Query,
  SDKMessage,
  SDKUserMessage
} from "@anthropic-ai/claude-agent-sdk"
import type {
  CancelResult,
  PromptInput,
  QuestionAnswer,
  RuntimeEmit
} from "@codevisor/agent-runtime"
import type { QuestionSpec, SessionGoal } from "@codevisor/api"

import type { Deferred } from "./internal.js"
import type { ClaudeSkillCall } from "./skill-tool.js"
import type { ClaudeSkills, ClaudeSlashCommand } from "./skills.js"
import type { SubagentTranscripts } from "./subagent-transcripts.js"

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

export type ClaudeQuery = AsyncIterable<SDKMessage> &
  Pick<
    Query,
    | "applyFlagSettings"
    | "getContextUsage"
    | "interrupt"
    | "setModel"
    | "setPermissionMode"
    | "supportedModels"
    | "usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET"
  > & {
    readonly supportedCommands: () => Promise<ReadonlyArray<ClaudeSlashCommand>>
  }

export type CurrentSession = () => ClaudeSession | undefined

export type ClaudeQueryFn = (input: {
  prompt: AsyncIterable<SDKUserMessage>
  options: ClaudeOptions
}) => ClaudeQuery

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

export interface ToolInputAccumulator {
  readonly toolName: string
  json: string
  lastEmit: number
  lastStats: string
  titledPath: string | undefined
  oldContent: string | null | undefined
}

export interface BackgroundTaskEntry {
  readonly id: string
  description: string
  status: string
  readonly taskType: string
  readonly toolUseId?: string
}

export interface ForkedCommand {
  readonly description: string
  readonly prompt: string | undefined
  readonly subagentType: string | undefined
  readonly taskId: string | undefined
  failed: boolean
  mirror: ForkedCommandMirror | undefined
}

export interface ForkedCommandMirror {
  readonly show: (message: SDKMessage) => void
  path: string | undefined
  offset: number
  shown: boolean
  timer: ReturnType<typeof setInterval> | undefined
}

export type ClaudeToolDecision =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string }

export interface PendingClaudeQuestion {
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly resolve: (result: ClaudeToolDecision) => void
  readonly respond: (answer: QuestionAnswer) => ClaudeToolDecision
}

export interface ClaudeSession {
  readonly key: string
  readonly sdkSessionId: string
  readonly cwd: string
  q: ClaudeQuery
  input: InputQueue
  readonly emit: RuntimeEmit
  readonly getSessionInfo: typeof sdkGetSessionInfo
  readonly abort: AbortController
  lastHarnessTitle: string | undefined
  turnActive: boolean
  turnId: string
  initiatedBy: "user" | "agent"
  pendingPrompt: Deferred<{ stopReason: string }> | undefined
  readonly deferredPrompts: Array<DeferredClaudePrompt>
  turnCompletion: Deferred<void> | undefined
  cancelInFlight: Promise<CancelResult> | undefined
  retired: boolean
  streamEnded: boolean
  pendingUserCommands: number
  interruptRequested: boolean
  truncationCount: number
  transientRetries: number
  streamRecoveries: number
  lastAssistantError: string | undefined
  lastErrorText: string | undefined
  lastUsageLimitText: string | undefined
  latestRateLimitInfo:
    | Extract<SDKMessage, { type: "rate_limit_event" }>["rate_limit_info"]
    | undefined
  latestContextUsage: { model: string | undefined; used: number } | undefined
  activeContextCompactionId: string | undefined
  currentMessageId: string | undefined
  currentMessageTextStreamed: boolean
  currentModel: string
  currentModeId: string
  currentEffort: string
  currentSpeed: "standard" | "fast"
  models: ReadonlyArray<ClaudeModel>
  readonly skills: ClaudeSkills
  readonly accumulators: Map<string, ToolInputAccumulator>
  readonly openToolCalls: Set<string>
  readonly taskToolUses: Map<string, ClaudeTaskToolUse>
  readonly skillCalls: Map<string, ClaudeSkillCall>
  readonly tasks: ClaudeTaskState
  readonly subagentMessageIds: Map<string, string>
  readonly subagentLastTexts: Map<string, string>
  readonly forkedCommands: Map<string, ForkedCommand>
  forkedCommandReplyPending: boolean
  readonly subagentTranscripts: SubagentTranscripts
  readonly backgroundTasks: Map<string, BackgroundTaskEntry>
  readonly hiddenBackgroundTaskIds: Set<string>
  readonly pendingQuestions: Map<string, PendingClaudeQuestion>
  currentGoal: SessionGoal | undefined
}
