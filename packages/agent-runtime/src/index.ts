import type { EventEnvelope, Harness, SessionGoal } from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import type { AgentSessionSummary } from "./agent-sessions.js"
import { accessSync, constants } from "node:fs"
import { Context, Effect, Layer } from "effect"
import type { BackgroundTerminalIntegration } from "./background-terminals.js"
import { makeAcpProvider, type AcpConnector } from "./providers/acp.js"
import { makeClaudeProvider } from "./providers/claude.js"
import { makeCodexProvider } from "./providers/codex/provider.js"
import {
  AgentRuntimeError,
  adapterPromise,
  runtimeError,
  runtimeEffect,
  type AgentProvider,
  type AgentSessionHandle,
  type AgentSessionMetadata,
  type HarnessDefinition,
  type HarnessAccountContext,
  type HarnessAuthInspection,
  type PromptInput,
  type PromptResult,
  type ProviderEnvironment,
  type ProviderId,
  type QuestionAnswer,
  type RuntimeEvent,
  type RuntimeEventSink,
  type SetGoalUpdate
} from "./types.js"

export * from "./types.js"
export * from "./attachments.js"
export * from "./background-terminals.js"
export * from "./diff-stats.js"
export * from "./shell-env.js"
export * from "./agent-sessions.js"
export {
  acpModelConfigId,
  acpModelConfigOption,
  acpPermissionOutcome,
  acpPermissionQuestion,
  acpProtocolVersion,
  acpPrompt,
  applyAcpModelSelection,
  extractAcpModelState,
  makeAcpProvider,
  normalizeModeState,
  runtimeEventFromNotification,
  stdioAcpConnector
} from "./providers/acp.js"
export type {
  AcpAgentConnection,
  AcpConnector,
  AcpHarnessLaunchRequest,
  AcpPromptCapabilities
} from "./providers/acp.js"
export { makeClaudeProvider } from "./providers/claude.js"
export type { ClaudeProviderConfig, ClaudeQueryFn } from "./providers/claude.js"
export { makeCodexProvider } from "./providers/codex/provider.js"
export type { CodexProviderConfig } from "./providers/codex/provider.js"
export { spawnCodexClient } from "./providers/codex/client.js"
export type { CodexClient, CodexConnector, CodexSpawnRequest } from "./providers/codex/client.js"

export interface AgentRuntimeConfig {
  readonly env?: NodeJS.ProcessEnv
  readonly executableExists?: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable?: (name: string, env: NodeJS.ProcessEnv) => string | undefined
  readonly connector?: AcpConnector
  readonly acpAuthProbeTimeoutMs?: number
  readonly harnessInspectionTimeoutMs?: number
  /// Server-owned terminals for agent background processes; providers surface
  /// long-running agent commands through it as attachable terminal tabs.
  /// Absent (tests, embedded runtimes), providers keep the plain behavior.
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  /// Extra providers (claude/codex) keyed by id; the ACP provider is always
  /// registered. Exposed for tests and incremental provider rollout.
  readonly providers?: Partial<Record<ProviderId, AgentProvider>>
  /// Re-resolves the runtime's environment (see `refreshEnvironment`).
  /// Typically `() => resolveShellEnv()` so PATH-based harness detection can
  /// pick up CLIs installed after the server started. Absent, refresh is a
  /// no-op and the environment stays fixed at `env ?? process.env`.
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
}

export interface AgentRuntimeService {
  readonly discoverHarnesses: Effect.Effect<ReadonlyArray<Harness>, AgentRuntimeError>
  /// Re-resolves the environment via the configured `resolveEnv` (no-op
  /// without one). Subsequent readiness checks and session launches see the
  /// refreshed PATH — this is how "Detect again" finds a CLI installed after
  /// server start. Concurrent refreshes share one in-flight resolution.
  readonly refreshEnvironment: Effect.Effect<void, AgentRuntimeError>
  /// Sessions from the harness's own on-disk store (run before/outside
  /// HerdMan). Empty for harnesses without a native store or a provider
  /// listing hook. Fails only for unknown harness ids.
  readonly listAgentSessions: (
    harnessId: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<ReadonlyArray<AgentSessionSummary>, AgentRuntimeError>
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
    account?: HarnessAccountContext
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
  readonly cancel: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  /// Closes a loaded agent session and its process (background shells
  /// included). No-op when the session is not loaded — archiving a session
  /// that was never opened this server-lifetime has nothing to tear down.
  readonly closeAgentSession: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<void, AgentRuntimeError>
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

export class AgentRuntime extends Context.Service<AgentRuntime, AgentRuntimeService>()(
  "@herdman/agent-runtime/AgentRuntime"
) {
  static readonly layer = (config: AgentRuntimeConfig = {}): Layer.Layer<AgentRuntime> =>
    Layer.succeed(AgentRuntime, AgentRuntime.of(makeAgentRuntime(config)))
}

export const harnessCatalog: ReadonlyArray<HarnessDefinition> = [
  // Claude Code is driven directly through the Agent SDK against the user's
  // own `claude` binary — no npx adapter, no Node requirement.
  {
    detectBinaries: ["claude"],
    id: "claude-code",
    installHint: "curl -fsSL https://claude.ai/install.sh | bash",
    name: "Claude Code",
    provider: "claude",
    symbolName: "sparkle"
  },
  // Codex is driven directly through `codex app-server` (JSONL JSON-RPC) —
  // no npx adapter, no Node requirement.
  {
    detectBinaries: ["codex"],
    // The ChatGPT/Codex desktop apps bundle the full CLI (same binary,
    // app-managed updates) and share ~/.codex auth with it — app-only users
    // get a working harness without installing the CLI. When both exist, the
    // Codex provider compares binary versions and uses the newer app-server.
    fallbackPaths: [
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "~/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
      "~/Applications/Codex.app/Contents/Resources/codex"
    ],
    id: "codex",
    installHint: "npm install -g @openai/codex",
    name: "Codex",
    provider: "codex",
    symbolName: "chevron.left.forwardslash.chevron.right"
  },
  npxHarness("gemini", "Gemini CLI", "diamond", ["gemini"], "@google/gemini-cli@0.49.0", ["--acp"]),
  executableHarness("opencode", "OpenCode", "curlybraces", ["opencode"], "opencode", ["acp"]),
  executableHarness("goose", "goose", "bird", ["goose"], "goose", ["acp"]),
  // Cursor is temporarily pulled: cursor-agent's headless/ACP mode fails with
  // connection errors to Cursor's backend even where interactive mode works
  // (their ACP path ignores the network.useHttp1ForAgent workaround).
  {
    detectBinaries: ["cursor-agent"],
    disabledReason: "Temporarily disabled — cursor-agent's ACP mode is unreliable (upstream issue)",
    id: "cursor",
    launch: { args: ["acp"], command: "cursor-agent", kind: "executable" },
    name: "Cursor",
    provider: "acp",
    symbolName: "cursorarrow.rays"
  },
  executableHarness("amp", "Amp", "bolt", ["amp-acp"], "amp-acp"),
  npxHarness("auggie", "Auggie CLI", "a.square", ["auggie"], "@augmentcode/auggie@0.31.0", [
    "--acp"
  ]),
  npxHarness("cline", "Cline", "terminal", ["cline"], "cline@3.0.34", ["--acp"]),
  npxHarness(
    "github-copilot-cli",
    "GitHub Copilot",
    "ellipsis.curlybraces",
    ["copilot"],
    "@github/copilot@1.0.65",
    ["--acp"]
  ),
  npxHarness("qwen-code", "Qwen Code", "q.square", ["qwen"], "@qwen-code/qwen-code@0.19.3", [
    "--acp",
    "--experimental-skills"
  ]),
  executableHarness("kimi", "Kimi CLI", "k.square", ["kimi"], "kimi", ["acp"]),
  npxHarness(
    "factory-droid",
    "Factory Droid",
    "wrench.and.screwdriver",
    ["droid"],
    "droid@0.159.1",
    ["exec", "--output-format", "acp-daemon"]
  ),
  executableHarness("devin", "Devin", "brain", ["devin"], "devin", ["acp"]),
  npxHarness("grok-build", "Grok Build", "x.square", ["grok"], "@xai-official/grok@0.2.76", [
    "agent",
    "stdio"
  ]),
  npxHarness("kilo", "Kilo", "shippingbox", ["kilo"], "@kilocode/cli@7.3.54", ["acp"])
]

interface ManagedSession {
  readonly harnessId: string
  readonly harnessAccountId?: string
  readonly cwd: string
  readonly handle: AgentSessionHandle
  metadata: AgentSessionMetadata
  sink: RuntimeEventSink
  chain: Promise<void>
}

export const makeAgentRuntime = (config: AgentRuntimeConfig = {}): AgentRuntimeService => {
  let currentEnv = config.env ?? process.env
  const locateExecutable = config.locateExecutable ?? locateExecutableOnPath
  const executableExists =
    config.executableExists ??
    ((name, environment) => locateExecutable(name, environment) !== undefined)
  // A getter so every provider sees environment refreshes without re-wiring:
  // providers read `environment.env` lazily at readiness/launch time.
  const environment: ProviderEnvironment = {
    get env() {
      return currentEnv
    },
    executableExists,
    locateExecutable
  }
  let envRefresh: Promise<void> | undefined
  const providers = new Map<ProviderId, AgentProvider>()
  const backgroundTerminals =
    config.backgroundTerminals === undefined
      ? {}
      : { backgroundTerminals: config.backgroundTerminals }
  providers.set(
    "acp",
    makeAcpProvider(environment, {
      ...backgroundTerminals,
      ...(config.connector === undefined ? {} : { connector: config.connector }),
      ...(config.acpAuthProbeTimeoutMs === undefined
        ? {}
        : { authProbeTimeoutMs: config.acpAuthProbeTimeoutMs })
    })
  )
  providers.set("claude", makeClaudeProvider(environment, backgroundTerminals))
  providers.set("codex", makeCodexProvider(environment, backgroundTerminals))
  for (const provider of Object.values(config.providers ?? {})) {
    providers.set(provider.id, provider)
  }
  const sessions = new Map<string, ManagedSession>()

  /// All session output funnels through here. Events append to the owning
  /// session's serial promise chain so the sink observes them in arrival
  /// order — including events with no prompt in flight, which is how
  /// agent-initiated turns reach the server.
  const dispatch = (event: RuntimeEvent): Promise<void> => {
    const session = sessions.get(event.subjectId)
    if (session === undefined) {
      return Promise.resolve()
    }
    if (
      event.kind === "session.updated" &&
      typeof event.payload === "object" &&
      event.payload !== null
    ) {
      const payload = event.payload as Record<string, unknown>
      if (Array.isArray(payload.configOptions)) {
        session.metadata = {
          ...session.metadata,
          configOptions: payload.configOptions as AgentSessionMetadata["configOptions"]
        }
      }
      if (typeof payload.modeId === "string" && session.metadata.modes !== undefined) {
        session.metadata = {
          ...session.metadata,
          modes: { ...session.metadata.modes, currentModeId: payload.modeId }
        }
      }
    }
    const next = session.chain
      .then(() => session.sink(event))
      .then(
        () => undefined,
        /* v8 ignore next -- defensive: a sink failure must not wedge the chain. */
        () => undefined
      )
    session.chain = next
    return next
  }

  const definitionFor = (
    harnessId: string
  ): Effect.Effect<
    { readonly definition: HarnessDefinition; readonly provider: AgentProvider },
    AgentRuntimeError
  > =>
    runtimeEffect("resolveHarness", () => {
      const definition = harnessCatalog.find((candidate) => candidate.id === harnessId)
      if (definition === undefined) {
        throw new Error(`Unknown harness: ${harnessId}`)
      }
      if (definition.disabledReason !== undefined) {
        throw new Error(`${definition.name} is unavailable: ${definition.disabledReason}`)
      }
      const provider = providers.get(definition.provider)
      /* v8 ignore next 3 -- every catalog provider id is registered above; guards future ids. */
      if (provider === undefined) {
        throw new Error(`No provider registered for harness: ${harnessId}`)
      }
      return { definition, provider }
    })

  const manageSession = (
    harnessId: string,
    metadata: AgentSessionMetadata,
    cwd: string,
    handle: AgentSessionHandle,
    sink: RuntimeEventSink,
    account?: HarnessAccountContext
  ): AgentSessionMetadata => {
    const sessionId = metadata.sessionId
    const previous = sessions.get(sessionId)
    if (previous !== undefined && previous.handle !== handle) {
      void Effect.runPromise(previous.handle.close).catch(() => undefined)
    }
    sessions.set(sessionId, {
      chain: Promise.resolve(),
      cwd,
      handle,
      harnessId,
      ...(account === undefined ? {} : { harnessAccountId: account.id }),
      metadata,
      sink
    })
    return metadata
  }

  const sessionFor = (sessionId: string): Effect.Effect<ManagedSession, AgentRuntimeError> =>
    runtimeEffect("sessionFor", () => {
      const session = sessions.get(sessionId)
      if (session === undefined) {
        throw new Error(`Agent session is not loaded: ${sessionId}`)
      }
      return session
    })

  return {
    discoverHarnesses: Effect.sync(() =>
      harnessCatalog.map((definition) => {
        const provider = providers.get(definition.provider)
        let readiness: Harness["readiness"]
        if (definition.disabledReason !== undefined) {
          readiness = { detail: definition.disabledReason, state: "unavailable" }
          /* v8 ignore start -- every catalog provider id is registered; guards future ids. */
        } else if (provider === undefined) {
          readiness = { detail: "Provider not available", state: "unavailable" }
          /* v8 ignore stop */
        } else {
          readiness = provider.readiness(definition)
        }
        return {
          id: definition.id,
          name: definition.name,
          symbolName: definition.symbolName,
          source: "registry",
          launchKind:
            definition.launch?.kind === "npx" ? ("npx" as const) : ("executable" as const),
          enabled: true,
          readiness,
          ...(definition.installHint === undefined ? {} : { installHint: definition.installHint })
        }
      })
    ),
    listAgentSessions: (harnessId, account) =>
      adapterPromise("listAgentSessions", async () => {
        const definition = harnessCatalog.find((candidate) => candidate.id === harnessId)
        if (definition === undefined) {
          throw new Error(`Unknown harness: ${harnessId}`)
        }
        // Deliberately no disabledReason check: a pulled integration's past
        // sessions still inform workspace suggestions.
        const provider = providers.get(definition.provider)
        /* v8 ignore next 3 -- every catalog provider id is registered above; guards future ids. */
        if (provider === undefined) {
          return []
        }
        const list = provider.listAgentSessions
        return list === undefined ? [] : await list(definition, account)
      }),
    refreshEnvironment: adapterPromise("refreshEnvironment", () => {
      const resolveEnv = config.resolveEnv
      if (resolveEnv === undefined) {
        return Promise.resolve()
      }
      // Concurrent refreshes (Settings + onboarding both rescanning) share
      // one shell probe instead of stacking login-shell invocations.
      envRefresh ??= resolveEnv()
        .then((resolved) => {
          currentEnv = resolved
        })
        .finally(() => {
          envRefresh = undefined
        })
      return envRefresh
    }),
    createAgentSession: (harnessId, cwd, sink, account, toolGateway) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        const created = yield* provider.createSession(
          definition,
          cwd,
          dispatch,
          account,
          toolGateway
        )
        manageSession(harnessId, created.metadata, cwd, created.handle, sink, account)
        return created.metadata.sessionId
      }),
    inspectHarness: (harnessId, cwd, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        const timeoutMs = config.harnessInspectionTimeoutMs ?? 15_000
        const created = yield* provider
          .createSession(
            definition,
            cwd,
            /* v8 ignore next -- inspection sessions are closed before they can emit. */
            () => Promise.resolve(),
            account
          )
          .pipe(
            Effect.timeout(timeoutMs),
            Effect.mapError((cause) =>
              runtimeError(
                "inspectHarness",
                cause._tag === "TimeoutError"
                  ? new Error(`Harness inspection timed out after ${timeoutMs}ms`)
                  : cause
              )
            )
          )
        void Effect.runPromise(created.handle.close).catch(() => undefined)
        return created.metadata
      }),
    loadAgentSession: (harnessId, agentSessionId, cwd, sink, account, toolGateway) =>
      Effect.gen(function* () {
        const existing = sessions.get(agentSessionId)
        if (
          existing !== undefined &&
          existing.harnessId === harnessId &&
          existing.cwd === cwd &&
          existing.harnessAccountId === account?.id
        ) {
          // Reconnects re-bind the sink (e.g. a restarted client re-loading a
          // live session) without tearing down the agent process.
          existing.sink = sink
          return existing.metadata
        }
        const { definition, provider } = yield* definitionFor(harnessId)
        const loaded = yield* provider.loadSession(
          definition,
          agentSessionId,
          cwd,
          dispatch,
          account,
          toolGateway
        )
        const metadata = loaded.metadata ?? { configOptions: [], sessionId: loaded.sessionId }
        return manageSession(harnessId, metadata, cwd, loaded.handle, sink, account)
      }),
    prompt: (sessionId, input) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.handle.prompt(input)
      }),
    cancel: (sessionId) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.handle.cancel
      }),
    closeAgentSession: (sessionId) =>
      Effect.gen(function* () {
        const session = sessions.get(sessionId)
        if (session === undefined) {
          return
        }
        sessions.delete(sessionId)
        yield* session.handle.close
      }),
    setMode: (sessionId, modeId) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.handle.setMode(modeId)
      }),
    setConfigOption: (sessionId, configId, value) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.handle.setConfigOption(configId, value)
      }),
    setGoal: (sessionId, update) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        const setGoal = session.handle.setGoal
        if (setGoal === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "setGoal",
              message: "Goals are not supported by this harness"
            })
          )
        }
        return yield* setGoal(update)
      }),
    clearGoal: (sessionId) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        const clearGoal = session.handle.clearGoal
        if (clearGoal === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "clearGoal",
              message: "Goals are not supported by this harness"
            })
          )
        }
        return yield* clearGoal
      }),
    answerQuestion: (sessionId, questionId, answer) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        const answerQuestion = session.handle.answerQuestion
        if (answerQuestion === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "answerQuestion",
              message: "Questions are not supported by this harness"
            })
          )
        }
        return yield* answerQuestion(questionId, answer)
      }),
    probeHarnessAuth: (harnessId, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        if (provider.probeAuth === undefined) {
          return { state: "notRequired" as const, methods: [], canLogout: false }
        }
        return yield* provider.probeAuth(definition, account)
      }),
    authenticateHarness: (harnessId, methodId, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        if (provider.authenticate === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "authenticate",
              message: "Authentication is not supported by this harness"
            })
          )
        }
        return yield* provider.authenticate(definition, methodId, account)
      }),
    logoutHarness: (harnessId, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        if (provider.logout === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "logout",
              message: "Logout is not supported by this harness"
            })
          )
        }
        return yield* provider.logout(definition, account)
      })
  }
}

export const toEventEnvelope = (
  serverId: string,
  id: number,
  event: RuntimeEvent
): EventEnvelope => ({
  id,
  serverId,
  kind: event.kind,
  subjectId: event.subjectId,
  createdAt: isoTimestamp(),
  payload: event.payload
})

function npxHarness(
  id: string,
  name: string,
  symbolName: string,
  detectBinaries: ReadonlyArray<string>,
  packageName: string,
  args: ReadonlyArray<string> = []
): HarnessDefinition {
  return {
    detectBinaries,
    id,
    launch: { args, kind: "npx", packageName },
    name,
    provider: "acp",
    symbolName
  }
}

function executableHarness(
  id: string,
  name: string,
  symbolName: string,
  detectBinaries: ReadonlyArray<string>,
  command: string,
  args: ReadonlyArray<string> = []
): HarnessDefinition {
  return {
    detectBinaries,
    id,
    launch: { args, command, kind: "executable" },
    name,
    provider: "acp",
    symbolName
  }
}

/// Default executable locator. Plain names are searched on PATH; candidates
/// with a leading `/` or `~/` (harness `fallbackPaths`, e.g. a CLI bundled
/// inside a desktop app) are probed directly, `~` expanding via env.HOME.
/// Exported for tests only.
export const locateExecutableOnPath = (
  name: string,
  env: NodeJS.ProcessEnv
): string | undefined => {
  if (name.startsWith("/") || name.startsWith("~/")) {
    if (name.startsWith("~/") && env.HOME === undefined) {
      return undefined
    }
    const candidate = name.startsWith("~/") ? `${env.HOME}${name.slice(1)}` : name
    try {
      accessSync(candidate, constants.X_OK)
      return candidate
    } catch {
      return undefined
    }
  }
  const path = env.PATH ?? ""
  for (const directory of path.split(":")) {
    const candidate = `${directory}/${name}`
    try {
      accessSync(candidate, constants.X_OK)
      return candidate
    } catch {
      continue
    }
  }
  return undefined
}
