import type { EventEnvelope, Harness } from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import { accessSync, constants } from "node:fs"
import { Context, Effect, Layer } from "effect"
import { makeAcpProvider, type AcpConnector } from "./providers/acp.js"
import {
  runtimeEffect,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type AgentSessionMetadata,
  type HarnessDefinition,
  type PromptResult,
  type ProviderEnvironment,
  type ProviderId,
  type RuntimeEvent,
  type RuntimeEventSink
} from "./types.js"

export * from "./types.js"
export * from "./diff-stats.js"
export {
  acpProtocolVersion,
  makeAcpProvider,
  runtimeEventFromNotification,
  stdioAcpConnector
} from "./providers/acp.js"
export type { AcpAgentConnection, AcpConnector, AcpHarnessLaunchRequest } from "./providers/acp.js"

export interface AgentRuntimeConfig {
  readonly env?: NodeJS.ProcessEnv
  readonly executableExists?: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable?: (name: string, env: NodeJS.ProcessEnv) => string | undefined
  readonly connector?: AcpConnector
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
    text: string
  ) => Effect.Effect<PromptResult, AgentRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<void, AgentRuntimeError>
}

export class AgentRuntime extends Context.Service<AgentRuntime, AgentRuntimeService>()(
  "@herdman/agent-runtime/AgentRuntime"
) {
  static readonly layer = (config: AgentRuntimeConfig = {}): Layer.Layer<AgentRuntime> =>
    Layer.succeed(AgentRuntime, AgentRuntime.of(makeAgentRuntime(config)))
}

export const harnessCatalog: ReadonlyArray<HarnessDefinition> = [
  npxHarness(
    "claude-code",
    "Claude Code",
    "sparkle",
    ["claude"],
    "@agentclientprotocol/claude-agent-acp@0.53.0"
  ),
  npxHarness(
    "codex",
    "Codex",
    "chevron.left.forwardslash.chevron.right",
    ["codex"],
    "@agentclientprotocol/codex-acp@1.0.2"
  ),
  npxHarness("gemini", "Gemini CLI", "diamond", ["gemini"], "@google/gemini-cli@0.49.0", ["--acp"]),
  executableHarness("opencode", "OpenCode", "curlybraces", ["opencode"], "opencode", ["acp"]),
  executableHarness("goose", "goose", "bird", ["goose"], "goose", ["acp"]),
  executableHarness("cursor", "Cursor", "cursorarrow.rays", ["cursor-agent"], "cursor-agent", [
    "acp"
  ]),
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
  providers.set(
    "acp",
    makeAcpProvider(
      environment,
      config.connector === undefined ? {} : { connector: config.connector }
    )
  )
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
      const provider = providers.get(definition.provider)
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
        return {
          id: definition.id,
          name: definition.name,
          symbolName: definition.symbolName,
          source: "registry",
          launchKind:
            definition.launch?.kind === "npx" ? ("npx" as const) : ("executable" as const),
          enabled: true,
          readiness:
            provider === undefined
              ? { detail: "Provider not available", state: "unavailable" as const }
              : provider.readiness(definition)
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
        const created = yield* provider.createSession(definition, cwd, () => Promise.resolve())
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
    prompt: (sessionId, text) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.handle.prompt(text)
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
