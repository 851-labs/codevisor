import type {
  EventKind,
  GoalStatus,
  Harness,
  QuestionAnswerEntry,
  SessionConfigOption,
  SessionGoal,
  SessionModeState
} from "@herdman/api"
import { Effect, Schema } from "effect"

export class AgentRuntimeError extends Schema.TaggedErrorClass<AgentRuntimeError>()(
  "AgentRuntimeError",
  {
    operation: Schema.String,
    message: Schema.String
  }
) {}

export interface RuntimeEvent {
  readonly kind: EventKind
  readonly subjectId: string
  readonly payload: unknown
}

export type RuntimeEventSink = (event: RuntimeEvent) => void | Promise<void>

/// Enqueues an event onto the owning session's serial sink chain. Resolves
/// once the sink has finished processing the event, so providers can flush
/// ordering-sensitive events (turn ends) before resolving a prompt.
export type RuntimeEmit = (event: RuntimeEvent) => Promise<void>

export interface PromptResult {
  readonly stopReason: string
}

/// One attachment resolved by the server before the prompt reaches a
/// provider: inline bytes for providers that embed content, plus a
/// materialized temp-file path for providers that reference files on disk.
export interface PromptAttachmentInput {
  readonly name: string
  readonly mimeType: string
  readonly kind: "image" | "file"
  readonly data: Buffer
  readonly path: string
}

export interface PromptInput {
  readonly text: string
  readonly attachments?: ReadonlyArray<PromptAttachmentInput>
}

export const normalizePromptInput = (input: string | PromptInput): PromptInput =>
  typeof input === "string" ? { text: input } : input

export interface AgentSessionMetadata {
  readonly sessionId: string
  readonly modes?: SessionModeState
  readonly configOptions: ReadonlyArray<SessionConfigOption>
  /// Whether the harness supports persistent session goals (codex goal mode).
  readonly supportsGoals?: boolean
}

/// Partial goal update mirroring codex `thread/goal/set`: omitted fields keep
/// their current value; `tokenBudget: null` clears the budget.
export interface SetGoalUpdate {
  readonly objective?: string
  readonly status?: GoalStatus
  readonly tokenBudget?: number | null
}

/// The human's reply to a blocking agent question. `answers` is keyed by the
/// per-question id from the emitted QuestionPayload; absent for `cancelled`.
export interface QuestionAnswer {
  readonly outcome: "answered" | "cancelled"
  readonly answers?: Readonly<Record<string, QuestionAnswerEntry>>
}

export type ProviderId = "acp" | "claude" | "codex"

export type HarnessLaunch =
  | {
      readonly kind: "npx"
      readonly packageName: string
      readonly args: ReadonlyArray<string>
    }
  | {
      readonly kind: "executable"
      readonly command: string
      readonly args: ReadonlyArray<string>
    }

export interface HarnessDefinition {
  readonly id: string
  readonly name: string
  readonly symbolName: string
  readonly detectBinaries: ReadonlyArray<string>
  /// Absolute paths probed when no detect binary is on PATH — CLIs bundled
  /// inside desktop apps (a leading `~/` expands via env.HOME). Lets users
  /// who installed the app but never the CLI still run the harness.
  readonly fallbackPaths?: ReadonlyArray<string>
  readonly provider: ProviderId
  /// Launch spec for the ACP provider's adapter process; native providers
  /// (claude/codex) drive the detected binary directly and omit it.
  readonly launch?: HarnessLaunch
  /// When set, the harness is reported unavailable with this reason and
  /// sessions cannot be created — used to pull a known-broken integration
  /// without deleting its catalog entry (existing sessions keep their name).
  readonly disabledReason?: string
  /// Copyable shell command that installs the harness CLI; surfaced next to
  /// "not installed" rows so users can install without leaving the app.
  readonly installHint?: string
}

export interface ProviderEnvironment {
  readonly env: NodeJS.ProcessEnv
  readonly executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable: (name: string, env: NodeJS.ProcessEnv) => string | undefined
}

/// Server-resolved account profile for one harness invocation. Credentials
/// remain owned by the harness inside this profile; HerdMan passes only the
/// profile environment to child processes.
export interface HarnessAccountContext {
  readonly id: string
  readonly profileKind: "default" | "managed"
  readonly profilePath?: string
  readonly env?: Readonly<Record<string, string>>
}

/// A session-scoped credential for HerdMan's single MCP tool gateway. It is
/// intentionally distinct from upstream MCP credentials, which never leave
/// the server process.
export interface ToolGatewayConfig {
  readonly name: string
  readonly url: string
  readonly bearerToken: string
}

export interface HarnessAuthInspection {
  readonly state: "authenticated" | "unauthenticated" | "notRequired" | "error"
  readonly methods: ReadonlyArray<{
    readonly id: string
    readonly name: string
    readonly description?: string
  }>
  readonly canLogout: boolean
  readonly detail?: string
}

/// Per-session control surface returned by a provider. The heavy agent
/// runtime lives in a child process owned by the handle; all session output
/// flows through the `RuntimeEmit` the handle was created with.
export interface AgentSessionHandle {
  readonly prompt: (input: string | PromptInput) => Effect.Effect<PromptResult, AgentRuntimeError>
  readonly cancel: Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    configId: string,
    value: string
  ) => Effect.Effect<void, AgentRuntimeError>
  /// Present only on harnesses that support goals (see
  /// AgentSessionMetadata.supportsGoals). Returns the updated goal snapshot.
  readonly setGoal?: (update: SetGoalUpdate) => Effect.Effect<SessionGoal, AgentRuntimeError>
  readonly clearGoal?: Effect.Effect<void, AgentRuntimeError>
  /// Resolves a blocking agent question previously emitted as a `question`
  /// event. Present only on harnesses that can ask questions; fails when the
  /// question id has no pending entry (already resolved, cancelled, or stale).
  readonly answerQuestion?: (
    questionId: string,
    answer: QuestionAnswer
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly close: Effect.Effect<void, AgentRuntimeError>
}

export interface CreatedAgentSession {
  readonly metadata: AgentSessionMetadata
  readonly handle: AgentSessionHandle
}

export interface LoadedAgentSession {
  readonly sessionId: string
  readonly handle: AgentSessionHandle
  /// Current session-specific configuration discovered while resuming. Older
  /// ACP adapters may not return it, in which case callers fall back to the
  /// harness capability catalog.
  readonly metadata?: AgentSessionMetadata
}

export interface AgentProvider {
  readonly id: ProviderId
  readonly readiness: (definition: HarnessDefinition) => Harness["readiness"]
  readonly createSession: (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ) => Effect.Effect<CreatedAgentSession, AgentRuntimeError>
  readonly loadSession: (
    definition: HarnessDefinition,
    agentSessionId: string,
    cwd: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ) => Effect.Effect<LoadedAgentSession, AgentRuntimeError>
  /// Sessions from the harness's own on-disk store (run before/outside
  /// HerdMan) — powers onboarding's workspace suggestions and "import
  /// existing chats". Absent when the harness has no native store to scan
  /// (generic ACP adapters).
  readonly listAgentSessions?: (
    definition: HarnessDefinition,
    account?: HarnessAccountContext
  ) => Promise<ReadonlyArray<import("./agent-sessions.js").AgentSessionSummary>>
  readonly probeAuth?: (
    definition: HarnessDefinition,
    account?: HarnessAccountContext
  ) => Effect.Effect<HarnessAuthInspection, AgentRuntimeError>
  readonly authenticate?: (
    definition: HarnessDefinition,
    methodId: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly logout?: (
    definition: HarnessDefinition,
    account?: HarnessAccountContext
  ) => Effect.Effect<void, AgentRuntimeError>
}

export const runtimeEffect = <A>(
  operation: string,
  run: () => A
): Effect.Effect<A, AgentRuntimeError> =>
  Effect.try({
    try: run,
    catch: (cause) => runtimeError(operation, cause)
  })

export const adapterPromise = <A>(
  operation: string,
  run: () => Promise<A>
): Effect.Effect<A, AgentRuntimeError> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => runtimeError(operation, cause)
  })

export const runtimeError = (operation: string, cause: unknown): AgentRuntimeError =>
  new AgentRuntimeError({
    operation,
    /* v8 ignore next -- local code throws Error values; this keeps external throwables readable. */
    message: cause instanceof Error ? cause.message : String(cause)
  })
