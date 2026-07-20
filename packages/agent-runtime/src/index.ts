import type { EventEnvelope, Harness, HarnessUsageLimits, SessionGoal } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import type { AgentSessionSummary } from "./agent-sessions.js"
import { accessSync, constants } from "node:fs"
import { Context, Effect, Layer } from "effect"
import type { BackgroundTerminalIntegration } from "./background-terminals.js"
import { makeAcpProvider, type AcpConnector } from "./providers/acp.js"
import { makeVersionProber } from "./version-probe.js"
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
  acpConfigOptionIds,
  acpModelConfigId,
  acpModelConfigOption,
  acpReasoningEffortConfigId,
  acpReasoningEffortConfigOption,
  acpPermissionOutcome,
  acpPermissionQuestion,
  acpProtocolVersion,
  acpPrompt,
  applyAcpModelSelection,
  applyAcpReasoningEffortSelection,
  extractAcpModelState,
  extractPiStartupInfo,
  isPiStartupInfoNotification,
  grokAskUserQuestion,
  grokGoalNotification,
  grokModeState,
  grokPlanApprovalQuestion,
  makeAcpProvider,
  normalizeAcpConfigOptions,
  normalizeModeState,
  piAssistantErrorFromSessionJsonl,
  runtimeEventFromNotification,
  stdioAcpConnector,
  testAcpConnection,
  usesAcpModelSelectionExtension
} from "./providers/acp.js"
export type {
  AcpAgentConnection,
  AcpConnectionTestResult,
  AcpConnector,
  AcpHarnessLaunchRequest,
  AcpPromptCapabilities,
  GrokGoalNotification
} from "./providers/acp.js"
export { makeClaudeProvider } from "./providers/claude.js"
export type { ClaudeProviderConfig, ClaudeQueryFn } from "./providers/claude.js"
export { makeCodexProvider } from "./providers/codex/provider.js"
export type { CodexProviderConfig } from "./providers/codex/provider.js"
export { spawnCodexClient } from "./providers/codex/client.js"
export type { CodexClient, CodexConnector, CodexSpawnRequest } from "./providers/codex/client.js"
export { makeVersionProber, parseVersionOutput } from "./version-probe.js"
export type { VersionProber, VersionProberOptions } from "./version-probe.js"

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
  "@codevisor/agent-runtime/AgentRuntime"
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
    installMethods: [
      { command: "curl -fsSL https://claude.ai/install.sh | bash", kind: "curl" },
      { kind: "npm", packageName: "@anthropic-ai/claude-code" }
    ],
    name: "Claude Code",
    provider: "claude",
    symbolName: "sparkle",
    update: {
      sources: [
        {
          // `claude update` is install-method aware (native/npm), but brew
          // installs refuse to self-update unless this env opt-in is set.
          apply: {
            args: ["update"],
            env: { CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE: "1" },
            kind: "selfUpdate"
          },
          check: { kind: "npm", packageName: "@anthropic-ai/claude-code" },
          when: "any"
        }
      ]
    }
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
    installMethods: [
      { cask: true, formula: "codex", kind: "brew" },
      { kind: "npm", packageName: "@openai/codex" }
    ],
    name: "Codex",
    provider: "codex",
    symbolName: "chevron.left.forwardslash.chevron.right",
    update: {
      sources: [
        {
          // App-bundled codex: `codex update` refuses (InstallMethod::Other),
          // so Codevisor updates the whole app bundle from its Sparkle feed.
          // The app ships its own (often pre-release) channel — never compare
          // it against the npm/brew stable line.
          apply: { kind: "appBundleSwap" },
          check: {
            appcastUrl: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml",
            appcastUrlX64: "https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml",
            kind: "sparkle"
          },
          when: "appBundle"
        },
        {
          apply: { args: ["update"], kind: "selfUpdate" },
          check: { formula: "codex", kind: "brew" },
          when: "brew"
        },
        {
          // `codex update` detects npm/pnpm/bun/standalone itself.
          apply: { args: ["update"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "@openai/codex" },
          when: "any"
        }
      ]
    }
  },
  // Pi exposes an RPC mode but not ACP directly. The pinned adapter bridges
  // Codevisor's existing ACP provider to the user's installed `pi` binary, so
  // Pi keeps ownership of its models, settings, extensions, and session store.
  {
    detectBinaries: ["pi"],
    id: "pi",
    installHint: "npm install -g @earendil-works/pi-coding-agent",
    installMethods: [{ kind: "npm", packageName: "@earendil-works/pi-coding-agent" }],
    launch: { args: [], kind: "npx", packageName: "pi-acp@0.0.31" },
    name: "Pi",
    provider: "acp",
    symbolName: "function",
    update: {
      sources: [
        {
          apply: { kind: "reinstall" },
          check: { kind: "npm", packageName: "@earendil-works/pi-coding-agent" },
          when: "any"
        }
      ]
    }
  },
  executableHarness("gemini", "Gemini CLI", "diamond", ["gemini"], "gemini", ["--acp"], {
    installMethods: [
      { kind: "npm", packageName: "@google/gemini-cli" },
      { formula: "gemini-cli", kind: "brew" }
    ],
    update: {
      // Gemini CLI has no self-update command (explicitly "not planned"
      // upstream) — reinstall via the detected origin.
      sources: [
        {
          apply: { kind: "reinstall" },
          check: { formula: "gemini-cli", kind: "brew" },
          when: "brew"
        },
        {
          apply: { kind: "reinstall" },
          check: { kind: "npm", packageName: "@google/gemini-cli" },
          when: "any"
        }
      ]
    }
  }),
  executableHarness("opencode", "OpenCode", "curlybraces", ["opencode"], "opencode", ["acp"], {
    installMethods: [
      { command: "curl -fsSL https://opencode.ai/install | bash", kind: "curl" },
      { kind: "npm", packageName: "opencode-ai" }
    ],
    update: {
      // `opencode upgrade` detects curl/npm/pnpm/bun/brew itself.
      sources: [
        {
          apply: { args: ["upgrade"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "opencode-ai" },
          when: "any"
        }
      ]
    }
  }),
  executableHarness("goose", "goose", "bird", ["goose"], "goose", ["acp"], {
    installMethods: [{ formula: "block-goose-cli", kind: "brew" }],
    update: {
      sources: [
        {
          // `goose update` blindly replaces the binary in place — on a brew
          // install that clobbers the Cellar copy, so delegate to brew.
          apply: { kind: "reinstall" },
          check: { formula: "block-goose-cli", kind: "brew" },
          when: "brew"
        },
        {
          apply: { args: ["update"], kind: "selfUpdate" },
          check: { kind: "github", repo: "block/goose" },
          when: "any"
        }
      ]
    }
  }),
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
  // Amp's harness runs through the separate `amp-acp` adapter binary, not the
  // `amp` CLI itself — no verified install/update channel for the adapter yet.
  executableHarness("amp", "Amp", "bolt", ["amp-acp"], "amp-acp"),
  executableHarness("auggie", "Auggie CLI", "a.square", ["auggie"], "auggie", ["--acp"], {
    installMethods: [{ kind: "npm", packageName: "@augmentcode/auggie" }],
    update: {
      // No self-update command; auggie's own background auto-updater covers
      // most installs, reinstall covers the rest.
      sources: [
        {
          apply: { kind: "reinstall" },
          check: { kind: "npm", packageName: "@augmentcode/auggie" },
          when: "any"
        }
      ]
    }
  }),
  executableHarness("cline", "Cline", "terminal", ["cline"], "cline", ["--acp"], {
    installMethods: [{ kind: "npm", packageName: "cline" }],
    update: {
      // `cline update` detects npm/pnpm/yarn/bun itself (npm-only distro).
      sources: [
        {
          apply: { args: ["update"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "cline" },
          when: "any"
        }
      ]
    }
  }),
  executableHarness(
    "github-copilot-cli",
    "GitHub Copilot",
    "ellipsis.curlybraces",
    ["copilot"],
    "copilot",
    ["--acp"],
    {
      installMethods: [{ kind: "npm", packageName: "@github/copilot" }],
      update: {
        // `copilot update` exists but is closed source; failures surface
        // gracefully as a failed lifecycle state.
        sources: [
          {
            apply: { args: ["update"], kind: "selfUpdate" },
            check: { kind: "npm", packageName: "@github/copilot" },
            when: "any"
          }
        ]
      }
    }
  ),
  executableHarness(
    "qwen-code",
    "Qwen Code",
    "q.square",
    ["qwen"],
    "qwen",
    ["--acp", "--experimental-skills"],
    {
      installMethods: [{ kind: "npm", packageName: "@qwen-code/qwen-code" }],
      update: {
        // No self-update command — reinstall via npm.
        sources: [
          {
            apply: { kind: "reinstall" },
            check: { kind: "npm", packageName: "@qwen-code/qwen-code" },
            when: "any"
          }
        ]
      }
    }
  ),
  executableHarness("kimi", "Kimi CLI", "k.square", ["kimi"], "kimi", ["acp"]),
  executableHarness(
    "factory-droid",
    "Factory Droid",
    "wrench.and.screwdriver",
    ["droid"],
    "droid",
    ["exec", "--output-format", "acp-daemon"],
    {
      installMethods: [{ command: "curl -fsSL https://app.factory.ai/cli | sh", kind: "curl" }],
      update: {
        sources: [
          // Droid's npm builds have auto-update disabled at build time
          // (deliberately pinned) — reinstall is the vendor-blessed path.
          {
            apply: { kind: "reinstall" },
            check: { kind: "npm", packageName: "droid" },
            when: "npm"
          },
          {
            // Standalone/curl installs self-update via `droid update`.
            apply: { args: ["update"], kind: "selfUpdate" },
            check: { kind: "npm", packageName: "droid" },
            when: "any"
          }
        ]
      }
    }
  ),
  executableHarness("devin", "Devin", "brain", ["devin"], "devin", ["acp"]),
  executableHarness("grok-build", "Grok Build", "x.square", ["grok"], "grok", ["agent", "stdio"]),
  executableHarness("kilo", "Kilo", "shippingbox", ["kilo"], "kilo", ["acp"], {
    installMethods: [{ kind: "npm", packageName: "@kilocode/cli" }],
    update: {
      // `kilo upgrade` detects curl/npm/yarn/pnpm/bun/brew itself.
      sources: [
        {
          apply: { args: ["upgrade"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "@kilocode/cli" },
          when: "any"
        }
      ]
    }
  })
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
  // Effective catalog: builtins first, then injected user-defined entries.
  // A colliding extra id is dropped so a custom entry can never shadow (or
  // break) a builtin harness. Both are `let`s: setExtraHarnesses swaps them
  // live (the custom-harness PUT route), so every internal consumer reads
  // them lazily rather than capturing.
  const withoutBuiltinCollisions = (
    definitions: ReadonlyArray<HarnessDefinition>
  ): ReadonlyArray<HarnessDefinition> =>
    definitions.filter((extra) => !harnessCatalog.some((builtin) => builtin.id === extra.id))
  let extraHarnesses = withoutBuiltinCollisions(config.extraHarnesses ?? [])
  let catalog: ReadonlyArray<HarnessDefinition> =
    extraHarnesses.length === 0 ? harnessCatalog : [...harnessCatalog, ...extraHarnesses]
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
  const versions = makeVersionProber(
    config.readVersionOutput === undefined ? {} : { readVersionOutput: config.readVersionOutput }
  )
  /// First detect binary (or absolute fallback path) present in the current
  /// environment — the same candidates providers scan for readiness.
  const locateHarnessBinary = (definition: HarnessDefinition): string | undefined => {
    for (const name of [...definition.detectBinaries, ...(definition.fallbackPaths ?? [])]) {
      const path = locateExecutable(name, currentEnv)
      if (path !== undefined) return path
    }
    return undefined
  }
  const locateReadyBinaries = (): ReadonlyArray<string> =>
    catalog.flatMap((definition) => {
      const path = locateHarnessBinary(definition)
      return path === undefined ? [] : [path]
    })
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
    if (typeof event.payload === "object" && event.payload !== null) {
      const payload = event.payload as Record<string, unknown>
      if (event.kind === "session.updated" && Array.isArray(payload.configOptions)) {
        session.metadata = {
          ...session.metadata,
          configOptions: payload.configOptions as AgentSessionMetadata["configOptions"]
        }
      }
      const modeId =
        event.kind === "session.updated" && typeof payload.modeId === "string"
          ? payload.modeId
          : event.kind === "session.output" &&
              payload.sessionUpdate === "current_mode_update" &&
              typeof payload.currentModeId === "string"
            ? payload.currentModeId
            : undefined
      if (modeId !== undefined && session.metadata.modes !== undefined) {
        session.metadata = {
          ...session.metadata,
          modes: { ...session.metadata.modes, currentModeId: modeId }
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
      const definition = catalog.find((candidate) => candidate.id === harnessId)
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
    get catalog() {
      return catalog
    },
    setExtraHarnesses: (definitions) => {
      extraHarnesses = withoutBuiltinCollisions(definitions)
      catalog =
        extraHarnesses.length === 0 ? harnessCatalog : [...harnessCatalog, ...extraHarnesses]
    },
    discoverHarnesses: Effect.sync(() =>
      catalog.map((definition) => {
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
        if (readiness.state === "ready") {
          const path = locateHarnessBinary(definition)
          if (path !== undefined) {
            // Versions come from the refreshEnvironment probe cache: the
            // server refreshes at boot and on every rescan, so discovery
            // stays synchronous and spawn-free.
            const version = versions.get(path)
            readiness = {
              ...readiness,
              path,
              ...(version === undefined ? {} : { version })
            }
          }
        }
        return {
          id: definition.id,
          name: definition.name,
          symbolName: definition.symbolName,
          source: extraHarnesses.includes(definition) ? "custom" : "registry",
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
        const definition = catalog.find((candidate) => candidate.id === harnessId)
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
    readHarnessUsageLimits: (harnessId, cwd, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        if (provider.readUsageLimits === undefined) {
          return {
            detail: "This harness does not expose account usage limits.",
            fetchedAt: isoTimestamp(),
            harnessId,
            state: "unavailable" as const,
            windows: []
          }
        }
        return yield* provider.readUsageLimits(definition, cwd, account)
      }),
    refreshEnvironment: adapterPromise("refreshEnvironment", () => {
      const resolveEnv = config.resolveEnv
      if (resolveEnv === undefined) {
        // Still settle version probes so a rescan without an env resolver
        // (embedded runtimes, tests) reports complete readiness.
        return versions.probe(locateReadyBinaries(), currentEnv)
      }
      // Concurrent refreshes (Settings + onboarding both rescanning) share
      // one shell probe instead of stacking login-shell invocations.
      envRefresh ??= resolveEnv()
        .then((resolved) => {
          currentEnv = resolved
        })
        // Awaited (not fire-and-forget) so the rescan response that follows
        // a refresh carries binary versions, not a cache miss.
        .then(() => versions.probe(locateReadyBinaries(), currentEnv))
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

function executableHarness(
  id: string,
  name: string,
  symbolName: string,
  detectBinaries: ReadonlyArray<string>,
  command: string,
  args: ReadonlyArray<string> = [],
  /// Lifecycle metadata (installMethods/update) and other optional
  /// definition fields that don't fit the positional shorthand.
  extra: Partial<
    Pick<HarnessDefinition, "installMethods" | "update" | "installHint" | "fallbackPaths">
  > = {}
): HarnessDefinition {
  return {
    detectBinaries,
    id,
    launch: { args, command, kind: "executable" },
    name,
    provider: "acp",
    symbolName,
    ...extra
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
