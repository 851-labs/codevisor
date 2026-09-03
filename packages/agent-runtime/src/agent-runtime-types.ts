import type { Harness, HarnessUsageLimits, SessionConfigOption, SessionGoal } from "@codevisor/api"
import type { AgentSessionSummary } from "./agent-sessions.js"
import { Effect } from "effect"
import type { BackgroundTerminalIntegration } from "./background-terminals.js"
import { AgentRuntimeError } from "./types.js"
import type {
  AgentProvider,
  AgentSessionMetadata,
  CancelResult,
  HarnessDefinition,
  HarnessAccountContext,
  HarnessAuthInspection,
  PromptInput,
  PromptResult,
  ProviderEnvironment,
  ProviderId,
  QuestionAnswer,
  RuntimeEventSink,
  SetGoalUpdate
} from "./types.js"

/// Shared context the runtime hands to every provider factory: the pieces of
/// runtime-owned state a harness adapter may integrate with.
export interface ProviderFactoryContext {
  readonly backgroundTerminals?: BackgroundTerminalIntegration
}

/// Constructs a provider against the runtime's live environment. Adapter
/// packages export `make*Provider` functions that plug in here; the app
/// composes the set it wants.
export type ProviderFactory = (
  environment: ProviderEnvironment,
  context: ProviderFactoryContext
) => AgentProvider

export interface AgentRuntimeConfig {
  readonly env?: NodeJS.ProcessEnv
  readonly executableExists?: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable?: (name: string, env: NodeJS.ProcessEnv) => string | undefined
  readonly harnessInspectionTimeoutMs?: number
  /// Server-owned terminals for agent background processes; providers surface
  /// long-running agent commands through it as attachable terminal tabs.
  /// Absent (tests, embedded runtimes), providers keep the plain behavior.
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  /// Harness adapters to register, constructed against the runtime's
  /// environment. The runtime registers no providers on its own — the app
  /// composes the adapter set (mix and match per deployment).
  readonly providerFactories?: ReadonlyArray<ProviderFactory>
  /// Pre-built providers keyed by id, merged after `providerFactories`
  /// (same-id wins). Exposed for tests and incremental provider rollout.
  readonly providers?: Partial<Record<ProviderId, AgentProvider>>
  /// Re-resolves the runtime's environment (see `refreshEnvironment`).
  /// Typically `() => resolveShellEnv()` so PATH-based harness detection can
  /// pick up CLIs installed after the server started. Absent, refresh is a
  /// no-op and the environment stays fixed at `env ?? process.env`.
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  /// Reads a detected binary's --version output for readiness enrichment;
  /// defaults to spawning the binary with the resolved environment. Exposed
  /// for tests.
  readonly readVersionOutput?: (path: string, env: NodeJS.ProcessEnv) => Promise<string>
  /// Additional harness definitions merged after the builtin catalog —
  /// user-defined custom ACP harnesses. Entries whose id collides with a
  /// builtin are dropped (the builtin wins); callers validate ids upstream.
  readonly extraHarnesses?: ReadonlyArray<HarnessDefinition>
}

export interface AgentRuntimeService {
  /// The effective harness catalog: builtins plus the current user-defined
  /// custom entries. A live view — read it lazily, don't capture it, so
  /// `setExtraHarnesses` swaps are observed. Consumers (harness auth,
  /// lifecycle) read definitions from here instead of the static
  /// `harnessCatalog` export so custom entries behave uniformly.
  readonly catalog: ReadonlyArray<HarnessDefinition>
  /// Replaces the injected custom entries (the custom-harness PUT route).
  /// Colliding ids are dropped exactly like the constructor path. Existing
  /// sessions on removed harnesses keep running; new lookups fail.
  readonly setExtraHarnesses: (definitions: ReadonlyArray<HarnessDefinition>) => void
  readonly discoverHarnesses: Effect.Effect<ReadonlyArray<Harness>, AgentRuntimeError>
  /// Re-resolves the environment via the configured `resolveEnv` (no-op
  /// without one). Subsequent readiness checks and session launches see the
  /// refreshed PATH — this is how "Detect again" finds a CLI installed after
  /// server start. Concurrent refreshes share one in-flight resolution.
  readonly refreshEnvironment: Effect.Effect<void, AgentRuntimeError>
  /// Sessions from the harness's own on-disk store (run before/outside
  /// Codevisor). Empty for harnesses without a native store or a provider
  /// listing hook. Fails only for unknown harness ids.
  readonly listAgentSessions: (
    harnessId: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<ReadonlyArray<AgentSessionSummary>, AgentRuntimeError>
  readonly readHarnessUsageLimits: (
    harnessId: string,
    cwd: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<HarnessUsageLimits, AgentRuntimeError>
  readonly createAgentSession: (
    harnessId: string,
    cwd: string,
    sink: RuntimeEventSink,
    account?: HarnessAccountContext,
    toolGateway?: import("./types.js").ToolGatewayConfig
  ) => Effect.Effect<string, AgentRuntimeError>
  readonly inspectHarness: (
    harnessId: string,
    cwd: string,
    account?: HarnessAccountContext,
    configSelections?: Readonly<Record<string, string>>
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly loadAgentSession: (
    harnessId: string,
    agentSessionId: string,
    cwd: string,
    sink: RuntimeEventSink,
    account?: HarnessAccountContext,
    toolGateway?: import("./types.js").ToolGatewayConfig
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly prompt: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<PromptResult, AgentRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<CancelResult, AgentRuntimeError>
  /// The agent session ids (harness-native ids, as passed to
  /// `loadAgentSession`) with a live process in this runtime. The restart
  /// drain snapshots these so a server restart can bring them back.
  readonly loadedAgentSessionIds: () => ReadonlyArray<string>
  /// Closes a loaded agent session and its process (background shells
  /// included). No-op when the session is not loaded — archiving a session
  /// that was never opened this server-lifetime has nothing to tear down.
  readonly closeAgentSession: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<ReadonlyArray<SessionConfigOption>, AgentRuntimeError>
  /// Fails with AgentRuntimeError when the session's harness has no goal
  /// support (see AgentSessionMetadata.supportsGoals).
  readonly setGoal: (
    sessionId: string,
    update: SetGoalUpdate
  ) => Effect.Effect<SessionGoal, AgentRuntimeError>
  readonly clearGoal: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  /// Fails when the harness cannot ask questions or the question is no longer
  /// pending (already resolved, cancelled with the turn, or stale replay).
  readonly answerQuestion: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly probeHarnessAuth: (
    harnessId: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<HarnessAuthInspection, AgentRuntimeError>
  readonly authenticateHarness: (
    harnessId: string,
    methodId: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly logoutHarness: (
    harnessId: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<void, AgentRuntimeError>
}
