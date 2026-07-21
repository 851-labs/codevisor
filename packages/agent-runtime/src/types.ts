import type {
  EventKind,
  GoalStatus,
  Harness,
  HarnessUsageLimits,
  QuestionAnswerEntry,
  SessionConfigOption,
  SessionGoal,
  SessionModeState
} from "@codevisor/api"
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
      /// Extra environment merged over the resolved shell env when spawning
      /// the adapter (user-defined custom harnesses). Account env still wins.
      readonly env?: Readonly<Record<string, string>>
    }

/// How an installed harness binary got onto the machine, detected from its
/// resolved path (brew prefix, node_modules, .app bundle, …). Update behavior
/// is keyed off this so we never fight the installer that owns the binary.
export type InstallOrigin = "npm" | "brew" | "curl" | "appBundle" | "standalone" | "unknown"

/// One way to install a harness CLI. `kind` doubles as the method id in the
/// API. Exactly one of the payload fields applies per kind.
export interface HarnessInstallMethodSpec {
  readonly kind: "brew" | "npm" | "curl"
  /// brew formula (or cask when `cask` is true), e.g. "block-goose-cli".
  readonly formula?: string
  readonly cask?: boolean
  /// npm package installed globally, e.g. "@openai/codex".
  readonly packageName?: string
  /// curl: the vendor's full install command, shown verbatim to the user
  /// before running (e.g. `curl -fsSL https://claude.ai/install.sh | bash`).
  readonly command?: string
}

/// Where to learn the latest available version for one install origin.
export type UpdateCheckSpec =
  | { readonly kind: "npm"; readonly packageName: string; readonly distTag?: string }
  | {
      readonly kind: "brew"
      /// Omit to infer the owning formula/cask from the resolved binary's
      /// Cellar/Caskroom path. This preserves channels such as `@latest`.
      readonly formula?: string
    }
  | { readonly kind: "github"; readonly repo: string }
  | {
      readonly kind: "sparkle"
      readonly appcastUrl: string
      readonly appcastUrlX64?: string
    }

/// How to apply an update for one install origin.
export type UpdateApplySpec =
  /// Run the harness's own updater (`codex update`, `opencode upgrade`, …).
  | {
      readonly kind: "selfUpdate"
      readonly args: ReadonlyArray<string>
      readonly env?: Readonly<Record<string, string>>
    }
  /// No native updater: rerun the install method matching the detected origin
  /// (npm reinstall at @latest, brew upgrade, curl script).
  | { readonly kind: "reinstall" }
  /// macOS app-bundled CLI (ChatGPT.app codex): replace the whole app bundle
  /// from its Sparkle feed. Server-side, darwin-only. The bundle path is
  /// derived from the detected binary (`<bundle>/Contents/Resources/<cli>`)
  /// unless pinned here.
  | { readonly kind: "appBundleSwap"; readonly bundlePath?: string }

/// Check + apply for one detected install origin; `when: "any"` is the
/// fallback row. Matching per-origin keeps version channels isolated (an
/// app-bundled alpha is never compared against the npm stable line).
export interface HarnessUpdateSource {
  readonly when: InstallOrigin | "any"
  readonly check: UpdateCheckSpec
  readonly apply: UpdateApplySpec
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
  /// Derived UI fallback — `installMethods` is the structured source.
  readonly installHint?: string
  /// Ways Codevisor can install this CLI, in vendor-preference order. Absent
  /// for harnesses we can't install (bundled-only, custom entries).
  readonly installMethods?: ReadonlyArray<HarnessInstallMethodSpec>
  /// Update sources keyed by detected install origin. Absent = no update
  /// support (custom entries, harnesses without a version channel).
  readonly update?: { readonly sources: ReadonlyArray<HarnessUpdateSource> }
}

export interface ProviderEnvironment {
  readonly env: NodeJS.ProcessEnv
  readonly executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable: (name: string, env: NodeJS.ProcessEnv) => string | undefined
}

/// Server-resolved account profile for one harness invocation. Credentials
/// remain owned by the harness inside this profile; Codevisor passes only the
/// profile environment to child processes.
export interface HarnessAccountContext {
  readonly id: string
  readonly profileKind: "default" | "managed"
  readonly profilePath?: string
  readonly env?: Readonly<Record<string, string>>
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
  /// Codevisor) — powers onboarding's workspace suggestions and "import
  /// existing chats". Absent when the harness has no native store to scan
  /// (generic ACP adapters).
  readonly listAgentSessions?: (
    definition: HarnessDefinition,
    account?: HarnessAccountContext
  ) => Promise<ReadonlyArray<import("./agent-sessions.js").AgentSessionSummary>>
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
