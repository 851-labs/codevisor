import type { EventEnvelope, Harness, SessionGoal } from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import { accessSync, constants } from "node:fs"
import { Context, Effect, Layer } from "effect"
import type { BackgroundTerminalIntegration } from "./background-terminals.js"
import { makeAcpProvider, type AcpConnector } from "./providers/acp.js"
import { makeClaudeProvider } from "./providers/claude.js"
import { makeCodexProvider } from "./providers/codex/provider.js"
import {
  AgentRuntimeError,
  runtimeEffect,
  type AgentProvider,
  type AgentSessionHandle,
  type AgentSessionMetadata,
  type HarnessDefinition,
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
export {
  acpPermissionOutcome,
  acpPermissionQuestion,
  acpProtocolVersion,
  acpPrompt,
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
  /// Server-owned terminals for agent background processes; providers surface
  /// long-running agent commands through it as attachable terminal tabs.
  /// Absent (tests, embedded runtimes), providers keep the plain behavior.
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  /// Extra providers (claude/codex) keyed by id; the ACP provider is always
  /// registered. Exposed for tests and incremental provider rollout.
  readonly providers?: Partial<Record<ProviderId, AgentProvider>>
}

export interface AgentRuntimeService {
  readonly discoverHarnesses: Effect.Effect<ReadonlyArray<Harness>, AgentRuntimeError>
  readonly createAgentSession: (
    harnessId: string,
    cwd: string,
    sink: RuntimeEventSink
  ) => Effect.Effect<string, AgentRuntimeError>
  readonly inspectHarness: (
    harnessId: string,
    cwd: string
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly loadAgentSession: (
    harnessId: string,
    agentSessionId: string,
    cwd: string,
    sink: RuntimeEventSink
  ) => Effect.Effect<string, AgentRuntimeError>
  readonly prompt: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<PromptResult, AgentRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
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
    name: "Claude Code",
    provider: "claude",
    symbolName: "sparkle"
  },
  // Codex is driven directly through `codex app-server` (JSONL JSON-RPC) —
  // no npx adapter, no Node requirement.
  {
    detectBinaries: ["codex"],
    id: "codex",
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
  readonly cwd: string
  readonly handle: AgentSessionHandle
  sink: RuntimeEventSink
  chain: Promise<void>
}

export const makeAgentRuntime = (config: AgentRuntimeConfig = {}): AgentRuntimeService => {
  const env = config.env ?? process.env
  const locateExecutable = config.locateExecutable ?? locateExecutableOnPath
  const executableExists =
    config.executableExists ??
    ((name, environment) => locateExecutable(name, environment) !== undefined)
  const environment: ProviderEnvironment = { env, executableExists, locateExecutable }
  const providers = new Map<ProviderId, AgentProvider>()
  const backgroundTerminals =
    config.backgroundTerminals === undefined
      ? {}
      : { backgroundTerminals: config.backgroundTerminals }
  providers.set(
    "acp",
    makeAcpProvider(environment, {
      ...backgroundTerminals,
      ...(config.connector === undefined ? {} : { connector: config.connector })
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
    sessionId: string,
    cwd: string,
    handle: AgentSessionHandle,
    sink: RuntimeEventSink
  ): string => {
    const previous = sessions.get(sessionId)
    if (previous !== undefined && previous.handle !== handle) {
      void Effect.runPromise(previous.handle.close).catch(() => undefined)
    }
    sessions.set(sessionId, { chain: Promise.resolve(), cwd, handle, harnessId, sink })
    return sessionId
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
          readiness
        }
      })
    ),
    createAgentSession: (harnessId, cwd, sink) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        const created = yield* provider.createSession(definition, cwd, dispatch)
        return manageSession(harnessId, created.metadata.sessionId, cwd, created.handle, sink)
      }),
    inspectHarness: (harnessId, cwd) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        const created = yield* provider.createSession(
          definition,
          cwd,
          /* v8 ignore next -- inspection sessions are closed before they can emit. */
          () => Promise.resolve()
        )
        void Effect.runPromise(created.handle.close).catch(() => undefined)
        return created.metadata
      }),
    loadAgentSession: (harnessId, agentSessionId, cwd, sink) =>
      Effect.gen(function* () {
        const existing = sessions.get(agentSessionId)
        if (existing !== undefined && existing.harnessId === harnessId && existing.cwd === cwd) {
          // Reconnects re-bind the sink (e.g. a restarted client re-loading a
          // live session) without tearing down the agent process.
          existing.sink = sink
          return agentSessionId
        }
        const { definition, provider } = yield* definitionFor(harnessId)
        const loaded = yield* provider.loadSession(definition, agentSessionId, cwd, dispatch)
        return manageSession(harnessId, loaded.sessionId, cwd, loaded.handle, sink)
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

const locateExecutableOnPath = (name: string, env: NodeJS.ProcessEnv): string | undefined => {
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
