import type { EventEnvelope, EventKind, Harness } from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import * as acp from "@agentclientprotocol/sdk"
import { spawn } from "node:child_process"
import type { ChildProcessWithoutNullStreams } from "node:child_process"
import { accessSync, constants } from "node:fs"
import { Readable, Writable } from "node:stream"
import { Context, Effect, Layer, Schema } from "effect"

export const acpProtocolVersion = acp.PROTOCOL_VERSION

export class AcpRuntimeError extends Schema.TaggedErrorClass<AcpRuntimeError>()("AcpRuntimeError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface RuntimeEvent {
  readonly kind: EventKind
  readonly subjectId: string
  readonly payload: unknown
}

export interface PromptResult {
  readonly stopReason: acp.StopReason
  readonly events: ReadonlyArray<RuntimeEvent>
}

export interface AcpHarnessLaunchRequest {
  readonly harnessId: string
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

export interface AcpAgentConnection {
  readonly createSession: (cwd: string) => Effect.Effect<string, AcpRuntimeError>
  readonly loadSession: (sessionId: string, cwd: string) => Effect.Effect<string, AcpRuntimeError>
  readonly prompt: (sessionId: string, text: string) => Effect.Effect<PromptResult, AcpRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<RuntimeEvent, AcpRuntimeError>
  readonly setMode: (
    sessionId: string,
    modeId: string
  ) => Effect.Effect<RuntimeEvent, AcpRuntimeError>
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<RuntimeEvent, AcpRuntimeError>
  readonly close: Effect.Effect<void, AcpRuntimeError>
}

export interface AcpConnector {
  readonly connect: (
    request: AcpHarnessLaunchRequest
  ) => Effect.Effect<AcpAgentConnection, AcpRuntimeError>
}

export interface AcpRuntimeConfig {
  readonly env?: NodeJS.ProcessEnv
  readonly executableExists?: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable?: (name: string, env: NodeJS.ProcessEnv) => string | undefined
  readonly connector?: AcpConnector
}

export interface AcpRuntimeService {
  readonly discoverHarnesses: Effect.Effect<ReadonlyArray<Harness>, AcpRuntimeError>
  readonly createAgentSession: (
    harnessId: string,
    cwd: string
  ) => Effect.Effect<string, AcpRuntimeError>
  readonly loadAgentSession: (
    harnessId: string,
    agentSessionId: string,
    cwd: string
  ) => Effect.Effect<string, AcpRuntimeError>
  readonly prompt: (sessionId: string, text: string) => Effect.Effect<PromptResult, AcpRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<RuntimeEvent, AcpRuntimeError>
  readonly setMode: (
    sessionId: string,
    modeId: string
  ) => Effect.Effect<RuntimeEvent, AcpRuntimeError>
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<RuntimeEvent, AcpRuntimeError>
}

export class AcpRuntime extends Context.Service<AcpRuntime, AcpRuntimeService>()(
  "@herdman/acp-runtime/AcpRuntime"
) {
  static readonly layer = (config: AcpRuntimeConfig = {}): Layer.Layer<AcpRuntime> =>
    Layer.succeed(AcpRuntime, AcpRuntime.of(makeAcpRuntime(config)))
}

interface HarnessDefinition {
  readonly id: string
  readonly name: string
  readonly symbolName: string
  readonly detectBinaries: ReadonlyArray<string>
  readonly launch: HarnessLaunch
}

type HarnessLaunch =
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

interface ReadyHarness {
  readonly definition: HarnessDefinition
  readonly command: string
  readonly args: ReadonlyArray<string>
}

interface ManagedSession {
  readonly harnessId: string
  readonly cwd: string
  readonly connection: AcpAgentConnection
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

export const makeAcpRuntime = (config: AcpRuntimeConfig = {}): AcpRuntimeService => {
  const env = config.env ?? process.env
  const locateExecutable = config.locateExecutable ?? locateExecutableOnPath
  const executableExists =
    config.executableExists ??
    ((name, environment) => locateExecutable(name, environment) !== undefined)
  const connector = config.connector ?? stdioAcpConnector
  const sessions = new Map<string, ManagedSession>()

  const readyHarnessFor = (harnessId: string): Effect.Effect<ReadyHarness, AcpRuntimeError> =>
    runtimeEffect("resolveHarness", () => {
      const definition = harnessCatalog.find((candidate) => candidate.id === harnessId)
      if (definition === undefined) {
        throw new Error(`Unknown ACP harness: ${harnessId}`)
      }
      const ready = resolveReadyHarness(definition, env, executableExists, locateExecutable)
      if (ready === undefined) {
        throw new Error(`ACP harness is unavailable: ${harnessId}`)
      }
      return ready
    })

  const connectHarness = (
    harnessId: string,
    cwd: string
  ): Effect.Effect<AcpAgentConnection, AcpRuntimeError> =>
    Effect.gen(function* () {
      const ready = yield* readyHarnessFor(harnessId)
      return yield* connector.connect({
        args: ready.args,
        command: ready.command,
        cwd,
        env,
        harnessId
      })
    })

  const manageSession = (
    harnessId: string,
    sessionId: string,
    cwd: string,
    connection: AcpAgentConnection
  ): string => {
    const previous = sessions.get(sessionId)
    if (previous !== undefined && previous.connection !== connection) {
      void Effect.runPromise(previous.connection.close).catch(() => undefined)
    }
    sessions.set(sessionId, { connection, cwd, harnessId })
    return sessionId
  }

  const sessionFor = (sessionId: string): Effect.Effect<ManagedSession, AcpRuntimeError> =>
    runtimeEffect("sessionFor", () => {
      const session = sessions.get(sessionId)
      if (session === undefined) {
        throw new Error(`ACP session is not loaded: ${sessionId}`)
      }
      return session
    })

  return {
    discoverHarnesses: Effect.succeed(
      discover(harnessCatalog, env, executableExists, locateExecutable)
    ),
    createAgentSession: (harnessId, cwd) =>
      Effect.gen(function* () {
        const connection = yield* connectHarness(harnessId, cwd)
        const sessionId = yield* connection.createSession(cwd)
        return manageSession(harnessId, sessionId, cwd, connection)
      }),
    loadAgentSession: (harnessId, agentSessionId, cwd) =>
      Effect.gen(function* () {
        const existing = sessions.get(agentSessionId)
        if (existing !== undefined && existing.harnessId === harnessId && existing.cwd === cwd) {
          return agentSessionId
        }
        const connection = yield* connectHarness(harnessId, cwd)
        const loadedSessionId = yield* connection.loadSession(agentSessionId, cwd)
        return manageSession(harnessId, loadedSessionId, cwd, connection)
      }),
    prompt: (sessionId, text) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.connection.prompt(sessionId, text)
      }),
    cancel: (sessionId) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.connection.cancel(sessionId)
      }),
    setMode: (sessionId, modeId) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.connection.setMode(sessionId, modeId)
      }),
    setConfigOption: (sessionId, configId, value) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.connection.setConfigOption(sessionId, configId, value)
      })
  }
}

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
const adapterPromise = <A>(
  operation: string,
  run: () => Promise<A>
): Effect.Effect<A, AcpRuntimeError> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => runtimeError(operation, cause)
  })

export const stdioAcpConnector: AcpConnector = {
  connect: (request) =>
    adapterPromise("connect", async () => {
      const child = spawn(request.command, [...request.args], {
        cwd: request.cwd,
        env: request.env,
        stdio: ["pipe", "pipe", "pipe"]
      })
      const stderr = captureStderr(child)
      const events = new Map<string, Array<RuntimeEvent>>()
      const connection = createClientApp((notification) => {
        const sessionEvents = events.get(notification.sessionId) ?? []
        sessionEvents.push(runtimeEventFromNotification(notification))
        events.set(notification.sessionId, sessionEvents)
      }).connect(
        acp.ndJsonStream(
          Writable.toWeb(child.stdin) as WritableStream<Uint8Array>,
          Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>
        )
      )
      child.once("exit", () => connection.close(new Error(stderr())))
      await connection.agent.request(acp.methods.agent.initialize, {
        clientCapabilities: {
          plan: {},
          terminal: false
        },
        clientInfo: {
          name: "HerdMan",
          title: "HerdMan",
          version: "0.1.0"
        },
        protocolVersion: acp.PROTOCOL_VERSION
      })
      return sdkConnection(connection, stderr, events)
    })
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

const sdkConnection = (
  connection: acp.ClientConnection,
  stderr: () => string,
  events: Map<string, Array<RuntimeEvent>>
): AcpAgentConnection => {
  const takeEvents = (sessionId: string, startIndex: number): ReadonlyArray<RuntimeEvent> =>
    (events.get(sessionId) ?? []).slice(startIndex)

  const eventCount = (sessionId: string): number => events.get(sessionId)?.length ?? 0

  connection.closed.catch(() => undefined)

  return {
    createSession: (cwd) =>
      adapterPromise("createSession", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.new, {
          cwd,
          mcpServers: []
        })
        return response.sessionId
      }),
    loadSession: (sessionId, cwd) =>
      adapterPromise("loadSession", async () => {
        await connection.agent.request(acp.methods.agent.session.load, {
          cwd,
          mcpServers: [],
          sessionId
        })
        return sessionId
      }),
    prompt: (sessionId, text) =>
      adapterPromise("prompt", async () => {
        const startIndex = eventCount(sessionId)
        const response = await connection.agent.request(acp.methods.agent.session.prompt, {
          prompt: [{ text, type: "text" }],
          sessionId
        })
        return {
          events: takeEvents(sessionId, startIndex),
          stopReason: response.stopReason
        }
      }),
    cancel: (sessionId) =>
      adapterPromise("cancel", async () => {
        await connection.agent.notify(acp.methods.agent.session.cancel, { sessionId })
        return {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { stopReason: "cancelled" }
        }
      }),
    setMode: (sessionId, modeId) =>
      adapterPromise("setMode", async () => {
        await connection.agent.request(acp.methods.agent.session.setMode, { modeId, sessionId })
        return {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { modeId }
        }
      }),
    setConfigOption: (sessionId, configId, value) =>
      adapterPromise("setConfigOption", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.setConfigOption, {
          configId,
          sessionId,
          value
        })
        return {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { configId, configOptions: response.configOptions, value }
        }
      }),
    close: runtimeEffect("close", () => {
      connection.close(new Error(stderr()))
    })
  }
}

const createClientApp = (
  onSessionUpdate: (notification: acp.SessionNotification) => void
): acp.ClientApp =>
  acp
    .client({ name: "HerdMan" })
    .onNotification(acp.methods.client.session.update, ({ params }) => {
      onSessionUpdate(params)
    })
    .onRequest(acp.methods.client.session.requestPermission, () => ({
      outcome: { outcome: "cancelled" }
    }))

const runtimeEventFromNotification = (notification: acp.SessionNotification): RuntimeEvent => {
  const update = notification.update
  switch (update.sessionUpdate) {
    case "user_message_chunk":
      return contentChunkEvent(notification.sessionId, "user", update)
    case "agent_message_chunk":
      return contentChunkEvent(notification.sessionId, "assistant", update)
    case "agent_thought_chunk":
      return contentChunkEvent(notification.sessionId, "assistant", update)
    case "session_info_update":
      return {
        kind: "session.updated",
        subjectId: notification.sessionId,
        payload: update
      }
    case "usage_update":
      return {
        kind: "session.updated",
        subjectId: notification.sessionId,
        payload: update
      }
    default:
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: update
      }
  }
}

const contentChunkEvent = (
  sessionId: string,
  role: "user" | "assistant",
  update: Extract<
    acp.SessionUpdate,
    {
      readonly sessionUpdate: "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk"
    }
  >
): RuntimeEvent => {
  const text = textFromContent(update.content)
  return {
    kind: "session.output",
    subjectId: sessionId,
    payload:
      text === undefined
        ? update
        : {
            messageId: update.messageId,
            role,
            text
          }
  }
}

const textFromContent = (content: acp.ContentBlock): string | undefined =>
  content.type === "text" ? content.text : undefined

const captureStderr = (child: ChildProcessWithoutNullStreams): (() => string) => {
  let buffer = ""
  child.stderr.setEncoding("utf8")
  child.stderr.on("data", (chunk: string) => {
    buffer = `${buffer}${chunk}`.slice(-8192)
  })
  return () => buffer
}
/* v8 ignore stop */

const discover = (
  definitions: ReadonlyArray<HarnessDefinition>,
  env: NodeJS.ProcessEnv,
  executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean,
  locateExecutable: (name: string, env: NodeJS.ProcessEnv) => string | undefined
): ReadonlyArray<Harness> =>
  definitions.map((definition) => {
    const ready = resolveReadyHarness(definition, env, executableExists, locateExecutable)
    return {
      id: definition.id,
      name: definition.name,
      symbolName: definition.symbolName,
      source: "registry",
      launchKind: definition.launch.kind === "npx" ? "npx" : "executable",
      enabled: true,
      readiness:
        ready === undefined
          ? unavailableReadiness(definition, env, executableExists)
          : { state: "ready" }
    }
  })

const resolveReadyHarness = (
  definition: HarnessDefinition,
  env: NodeJS.ProcessEnv,
  executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean,
  locateExecutable: (name: string, env: NodeJS.ProcessEnv) => string | undefined
): ReadyHarness | undefined => {
  if (!definition.detectBinaries.some((binary) => executableExists(binary, env))) {
    return undefined
  }

  switch (definition.launch.kind) {
    case "npx": {
      const command =
        locateExecutable("npx", env) ?? (executableExists("npx", env) ? "npx" : undefined)
      return command === undefined
        ? undefined
        : {
            args: ["-y", definition.launch.packageName, ...definition.launch.args],
            command,
            definition
          }
    }
    case "executable": {
      const located = locateExecutable(definition.launch.command, env)
      if (located !== undefined) {
        return {
          args: definition.launch.args,
          command: located,
          definition
        }
      }
      /* v8 ignore next -- installed executable catalog entries currently use the launch command as their detect binary. */
      if (executableExists(definition.launch.command, env)) {
        return {
          args: definition.launch.args,
          command: definition.launch.command,
          definition
        }
      }
      /* v8 ignore next -- installed executable catalog entries currently use the launch command as their detect binary. */
      return undefined
    }
  }
}

const unavailableReadiness = (
  definition: HarnessDefinition,
  env: NodeJS.ProcessEnv,
  executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean
): Harness["readiness"] => {
  const installed = definition.detectBinaries.some((binary) => executableExists(binary, env))
  if (!installed) {
    return { detail: "CLI not found on PATH", state: "unavailable" }
  }
  /* v8 ignore next -- installed executable catalog entries are ready before unavailableReadiness is called. */
  if (definition.launch.kind === "npx") {
    return { detail: "Requires npx", state: "unavailable" }
  }
  /* v8 ignore next -- installed executable catalog entries are ready before unavailableReadiness is called. */
  return { detail: `${definition.launch.command} not found on PATH`, state: "unavailable" }
}

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

const runtimeEffect = <A>(operation: string, run: () => A): Effect.Effect<A, AcpRuntimeError> =>
  Effect.try({
    try: run,
    catch: (cause) => runtimeError(operation, cause)
  })

const runtimeError = (operation: string, cause: unknown): AcpRuntimeError =>
  new AcpRuntimeError({
    operation,
    /* v8 ignore next -- local code throws Error values; this keeps external throwables readable. */
    message: cause instanceof Error ? cause.message : String(cause)
  })
