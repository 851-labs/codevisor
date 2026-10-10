import type {
  EventKind,
  GoalStatus,
  Harness,
  HarnessUsageLimits,
  QuestionAnswerEntry,
  SessionConfigOption,
  SessionGoal,
  SessionModeState,
  SessionSkills
} from "@codevisor/api"
import { Effect, Schema } from "effect"

import type { HarnessDefinition, ProviderId } from "./harness-definition-types.js"

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

/// Provider cancellation outcome. A forced provider-side recovery can
/// terminalize the durable turn while leaving the underlying process/query
/// unsafe for another prompt; the runtime manager must retire that handle.
export interface CancelResult {
  readonly runtimeState: "reusable" | "retire"
}

/// One attachment resolved by the server before the prompt reaches a
/// provider: a materialized temp-file path every provider can reference, plus
/// inline content for providers that embed it. The server never reads a whole
/// attachment into memory unless it may be embedded.
export interface PromptAttachmentInput {
  readonly name: string
  readonly mimeType: string
  readonly kind: "image" | "file"
  readonly sizeBytes: number
  readonly path: string
  /// Embeddable content, already sized for provider limits: images are
  /// normalized (possibly re-encoded, so `mimeType` may differ from the
  /// original) and PDFs are present only when small enough to inline.
  readonly inline?: { readonly mimeType: string; readonly data: Buffer }
  /// The attachment is a kind providers embed, but it could not be made to
  /// fit. Providers fall back to the path and tell the model why.
  readonly inlineOmitted?: boolean
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
  /// Skills the session can invoke, when the harness can list them. Live
  /// sessions also stream changes as `available_skills_update` output.
  readonly skills?: SessionSkills
  /// Requested selections (config id → requested value) that could not be
  /// applied to this snapshot. Only inspection reports it.
  readonly unappliedConfigSelections?: Readonly<Record<string, string>>
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

export type {
  ProviderId,
  HarnessLaunch,
  InstallOrigin,
  HarnessInstallMethodSpec,
  UpdateCheckSpec,
  UpdateApplySpec,
  HarnessUpdateSource,
  NativeMcpConfigSpec,
  HarnessSkillsSpec,
  HarnessDefinition
} from "./harness-definition-types.js"

export interface ProviderEnvironment {
  readonly env: NodeJS.ProcessEnv
  readonly executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable: (name: string, env: NodeJS.ProcessEnv) => string | undefined
}

/// Server-resolved account profile for one harness invocation. Credentials
/// remain owned by the harness inside this profile; Codevisor passes only the
/// profile environment to child processes.
/// A copy of `env` without the variables an account context asks to hide
/// from the harness process. Adapters call this on the parent environment
/// before layering the account's own `env` on top.
export const withoutEnv = <T extends Readonly<Record<string, string | undefined>>>(
  env: T,
  unset: ReadonlyArray<string> | undefined
): T => {
  if (unset === undefined || unset.length === 0) return env
  const result: Record<string, string | undefined> = { ...env }
  for (const name of unset) delete result[name]
  return result as T
}

export interface HarnessAccountContext {
  readonly id: string
  readonly profileKind: "default" | "managed"
  readonly env?: Readonly<Record<string, string>>
  /// Inherited variables the harness process must NOT see (a user's own
  /// `GROK_AUTH`, say). Adapters drop these from the parent environment before
  /// applying `env`. Setting a variable to "" is not the same: several CLIs
  /// treat an empty-but-present credential as "supplied", not "absent".
  readonly unsetEnv?: ReadonlyArray<string>
  /// Runs before each turn. A host that keeps the harness's credential files
  /// current uses it to catch up first, e.g. after the machine slept through
  /// a scheduled refresh. Best-effort: it never fails the turn.
  readonly beforeTurn?: () => Promise<void>
  /// Host-owned credentials: adapters never receive the rotating refresh token.
  readonly oauth?: {
    readonly token: (rejectedAccessToken?: string) => Promise<{
      readonly accessToken: string
      readonly accountId?: string
      readonly planType?: string
    }>
  }
}

/// A session-scoped credential for Codevisor's single MCP tool gateway. It is
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
  readonly cancel: Effect.Effect<CancelResult, AgentRuntimeError>
  readonly setMode: (modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    configId: string,
    value: string
  ) => Effect.Effect<ReadonlyArray<SessionConfigOption>, AgentRuntimeError>
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

/// Per-call tuning for session creation. Adapters that don't recognize an
/// option simply ignore it (implementations may accept fewer parameters).
export interface CreateSessionOptions {
  /// How long to wait for the harness's model list before returning without
  /// one. Interactive session creation keeps a short budget so chat startup
  /// stays snappy; capability INSPECTION exists to fetch the list, so it
  /// grants most of its own timeout — a cold CLI spawn on a slow machine
  /// (a containerized Linux server) routinely needs more than the default.
  readonly modelListTimeoutMs?: number
  /// How long to wait for a skill list the harness pushes asynchronously
  /// (ACP's `available_commands_update`) before returning metadata without
  /// one. Live sessions receive the list as session output regardless, so
  /// only capability inspection asks to wait.
  readonly skillListTimeoutMs?: number
  /// The chat's saved picker selections (config id → value). Harnesses that
  /// can take them as process start options (Claude's model, effort, and
  /// speed) start with them, so a fresh or resumed process never runs on
  /// its own default before the selections are restored.
  readonly configSelections?: Readonly<Record<string, string>>
}

export interface AgentProvider {
  readonly id: ProviderId
  readonly readiness: (definition: HarnessDefinition) => Harness["readiness"]
  readonly createSession: (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig,
    sessionOptions?: CreateSessionOptions
  ) => Effect.Effect<CreatedAgentSession, AgentRuntimeError>
  readonly loadSession: (
    definition: HarnessDefinition,
    agentSessionId: string,
    cwd: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig,
    sessionOptions?: CreateSessionOptions
  ) => Effect.Effect<LoadedAgentSession, AgentRuntimeError>
  /// Sessions from the harness's own on-disk store (run before/outside
  /// Codevisor) — powers onboarding's workspace suggestions and "import
  /// existing chats". Absent when the harness has no native store to scan
  /// (generic ACP adapters).
  readonly listAgentSessions?: (
    definition: HarnessDefinition,
    account?: HarnessAccountContext,
    options?: import("./agent-sessions.js").AgentSessionListOptions
  ) => Promise<ReadonlyArray<import("./agent-sessions.js").AgentSessionSummary>>
  /// Maps a saved picker value the option list no longer offers verbatim
  /// onto the entry it now names, or `undefined` when it is really gone.
  /// Pure: consults only the offered options. Claude uses it for model ids
  /// that change between CLI releases.
  readonly reconcileConfigValue?: (option: SessionConfigOption, value: string) => string | undefined
  readonly readUsageLimits?: (
    definition: HarnessDefinition,
    cwd: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<HarnessUsageLimits, AgentRuntimeError>
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
