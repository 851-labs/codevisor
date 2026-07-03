import * as acp from "@agentclientprotocol/sdk"
import type {
  ContentBlock as AcpContentBlock,
  NewSessionResponse,
  SessionConfigOption as AcpSessionConfigOption,
  SessionConfigSelectGroup as AcpSessionConfigSelectGroup,
  SessionConfigSelectOption as AcpSessionConfigSelectOption,
  SessionModeState as AcpSessionModeState
} from "@agentclientprotocol/sdk"
import type {
  Harness,
  SessionConfigOption,
  SessionConfigSelectGroup,
  SessionConfigSelectOption,
  SessionModeState
} from "@herdman/api"
import { randomUUID } from "node:crypto"
import { spawn } from "node:child_process"
import type { ChildProcessWithoutNullStreams } from "node:child_process"
import { Readable, Writable } from "node:stream"
import { Effect } from "effect"
import { withAttachmentNotes } from "../attachments.js"
import { diffStatsFromTexts } from "../diff-stats.js"
import type { DiffStat } from "@herdman/api"
import {
  adapterPromise,
  normalizePromptInput,
  runtimeEffect,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type AgentSessionMetadata,
  type CreatedAgentSession,
  type HarnessDefinition,
  type LoadedAgentSession,
  type PromptInput,
  type ProviderEnvironment,
  type RuntimeEmit,
  type RuntimeEvent
} from "../types.js"

export const acpProtocolVersion = acp.PROTOCOL_VERSION

export interface AcpHarnessLaunchRequest {
  readonly harnessId: string
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

/// One live ACP adapter process. Session output is pushed to the `emit`
/// callback for the connection's whole lifetime — including notifications
/// that arrive between turns — which is what keeps background/agent-initiated
/// work from being dropped.
export interface AcpAgentConnection {
  readonly createSession: (cwd: string) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly loadSession: (sessionId: string, cwd: string) => Effect.Effect<string, AgentRuntimeError>
  readonly prompt: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<{ readonly stopReason: string }, AgentRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  /// Returns the agent's updated config options (raw ACP shape) so the caller
  /// can broadcast them.
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<unknown, AgentRuntimeError>
  readonly close: Effect.Effect<void, AgentRuntimeError>
}

export interface AcpConnector {
  readonly connect: (
    request: AcpHarnessLaunchRequest,
    emit: RuntimeEmit
  ) => Effect.Effect<AcpAgentConnection, AgentRuntimeError>
}

interface ResolvedLaunch {
  readonly command: string
  readonly args: ReadonlyArray<string>
}

const resolveLaunch = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment
): ResolvedLaunch | undefined => {
  const launch = definition.launch
  if (launch === undefined) {
    return undefined
  }
  if (
    !definition.detectBinaries.some((binary) =>
      environment.executableExists(binary, environment.env)
    )
  ) {
    return undefined
  }
  switch (launch.kind) {
    case "npx": {
      const command =
        environment.locateExecutable("npx", environment.env) ??
        (environment.executableExists("npx", environment.env) ? "npx" : undefined)
      return command === undefined
        ? undefined
        : { args: ["-y", launch.packageName, ...launch.args], command }
    }
    case "executable": {
      const located = environment.locateExecutable(launch.command, environment.env)
      if (located !== undefined) {
        return { args: launch.args, command: located }
      }
      /* v8 ignore next 3 -- installed executable catalog entries currently use the launch command as their detect binary. */
      if (environment.executableExists(launch.command, environment.env)) {
        return { args: launch.args, command: launch.command }
      }
      /* v8 ignore next */
      return undefined
    }
  }
}

const unavailableReadiness = (
  definition: HarnessDefinition,
  environment: ProviderEnvironment
): Harness["readiness"] => {
  const installed = definition.detectBinaries.some((binary) =>
    environment.executableExists(binary, environment.env)
  )
  if (!installed) {
    return { detail: "CLI not found on PATH", state: "unavailable" }
  }
  /* v8 ignore next 3 -- installed executable catalog entries are ready before unavailableReadiness is called. */
  if (definition.launch?.kind === "npx") {
    return { detail: "Requires npx", state: "unavailable" }
  }
  /* v8 ignore next 2 */
  const command =
    definition.launch?.kind === "executable" ? definition.launch.command : definition.id
  return { detail: `${command} not found on PATH`, state: "unavailable" }
}

export interface AcpProviderConfig {
  readonly connector?: AcpConnector
}

export const makeAcpProvider = (
  environment: ProviderEnvironment,
  config: AcpProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? stdioAcpConnector

  const connect = (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit
  ): Effect.Effect<AcpAgentConnection, AgentRuntimeError> =>
    Effect.gen(function* () {
      const launch = yield* runtimeEffect("resolveHarness", () => {
        const resolved = resolveLaunch(definition, environment)
        if (resolved === undefined) {
          throw new Error(`ACP harness is unavailable: ${definition.id}`)
        }
        return resolved
      })
      return yield* connector.connect(
        {
          args: launch.args,
          command: launch.command,
          cwd,
          env: environment.env,
          harnessId: definition.id
        },
        emit
      )
    })

  const handleFor = (
    connection: AcpAgentConnection,
    sessionId: string,
    emit: RuntimeEmit
  ): AgentSessionHandle => ({
    prompt: (input) =>
      Effect.gen(function* () {
        const turnId = randomUUID()
        yield* adapterPromise("promptTurnStart", () =>
          emit(turnLifecycleEvent(sessionId, turnId, "started"))
        )
        const result = yield* connection.prompt(sessionId, input)
        yield* adapterPromise("promptTurnEnd", () =>
          emit(turnLifecycleEvent(sessionId, turnId, "ended", result.stopReason))
        )
        return result
      }),
    cancel: connection.cancel(sessionId),
    setMode: (modeId) =>
      Effect.gen(function* () {
        yield* connection.setMode(sessionId, modeId)
        yield* adapterPromise("setModeEvent", () =>
          emit({ kind: "session.updated", subjectId: sessionId, payload: { modeId } })
        )
      }),
    setConfigOption: (configId, value) =>
      Effect.gen(function* () {
        const configOptions = yield* connection.setConfigOption(sessionId, configId, value)
        yield* adapterPromise("setConfigOptionEvent", () =>
          emit({
            kind: "session.updated",
            subjectId: sessionId,
            payload: { configId, configOptions, value }
          })
        )
      }),
    close: connection.close
  })

  return {
    id: "acp",
    readiness: (definition) =>
      resolveLaunch(definition, environment) === undefined
        ? unavailableReadiness(definition, environment)
        : { state: "ready" },
    createSession: (definition, cwd, emit): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
      Effect.gen(function* () {
        const connection = yield* connect(definition, cwd, emit)
        const metadata = yield* connection.createSession(cwd)
        return { handle: handleFor(connection, metadata.sessionId, emit), metadata }
      }),
    loadSession: (
      definition,
      agentSessionId,
      cwd,
      emit
    ): Effect.Effect<LoadedAgentSession, AgentRuntimeError> =>
      Effect.gen(function* () {
        const connection = yield* connect(definition, cwd, emit)
        const sessionId = yield* connection.loadSession(agentSessionId, cwd)
        return { handle: handleFor(connection, sessionId, emit), sessionId }
      })
  }
}

const turnLifecycleEvent = (
  sessionId: string,
  turnId: string,
  turnState: "started" | "ended",
  stopReason?: string
): RuntimeEvent => ({
  kind: "session.updated",
  subjectId: sessionId,
  payload: {
    initiatedBy: "user",
    turnId,
    turnState,
    ...(stopReason === undefined ? {} : { stopReason })
  }
})

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
export const stdioAcpConnector: AcpConnector = {
  connect: (request, emit) =>
    adapterPromise("connect", async () => {
      const child = spawn(request.command, [...request.args], {
        cwd: request.cwd,
        env: request.env,
        stdio: ["pipe", "pipe", "pipe"]
      })
      let closeConnection: ((error: Error) => void) | undefined
      const spawnFailure = new Promise<never>((_resolve, reject) => {
        child.once("error", (error) => {
          closeConnection?.(error)
          reject(error)
        })
      })
      spawnFailure.catch(() => undefined)
      const stderr = captureStderr(child)
      const connection = createClientApp((notification) => {
        void emit(runtimeEventFromNotification(notification)).catch(() => undefined)
      }).connect(
        acp.ndJsonStream(
          Writable.toWeb(child.stdin) as WritableStream<Uint8Array>,
          Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>
        )
      )
      closeConnection = (error) => connection.close(error)
      child.once("exit", () => connection.close(new Error(stderr())))
      const initialized = await Promise.race([
        connection.agent.request(acp.methods.agent.initialize, {
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
        }),
        spawnFailure
      ])
      return sdkConnection(
        connection,
        stderr,
        () => {
          child.kill()
        },
        initialized?.agentCapabilities?.promptCapabilities ?? {}
      )
    })
}

export interface AcpPromptCapabilities {
  readonly image?: boolean
}

/// Builds the session/prompt content blocks: images inline as base64 when the
/// harness declared image support, otherwise (and for all non-image files) a
/// temp-file path note in the text block. Exported for unit tests — the live
/// wiring runs inside the stdio SDK connection.
export const acpPrompt = (
  input: PromptInput,
  capabilities: AcpPromptCapabilities
): Array<AcpContentBlock> => {
  const attachments = input.attachments ?? []
  const inline =
    capabilities.image === true
      ? attachments.filter((attachment) => attachment.kind === "image")
      : []
  const noted = attachments.filter((attachment) => !inline.includes(attachment))
  const text = withAttachmentNotes(input.text, noted)
  const blocks: Array<AcpContentBlock> = []
  if (text !== "" || inline.length === 0) {
    blocks.push({ text, type: "text" })
  }
  for (const image of inline) {
    blocks.push({ data: image.data.toString("base64"), mimeType: image.mimeType, type: "image" })
  }
  return blocks
}

const sdkConnection = (
  connection: acp.ClientConnection,
  stderr: () => string,
  terminate: () => void = () => undefined,
  promptCapabilities: AcpPromptCapabilities = {}
): AcpAgentConnection => {
  connection.closed.catch(() => undefined)

  return {
    createSession: (cwd) =>
      adapterPromise("createSession", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.new, {
          cwd,
          mcpServers: []
        })
        return sessionMetadata(response)
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
    prompt: (sessionId, input) =>
      adapterPromise("prompt", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.prompt, {
          prompt: acpPrompt(normalizePromptInput(input), promptCapabilities),
          sessionId
        })
        return { stopReason: response.stopReason }
      }),
    cancel: (sessionId) =>
      adapterPromise("cancel", async () => {
        await connection.agent.notify(acp.methods.agent.session.cancel, { sessionId })
      }),
    setMode: (sessionId, modeId) =>
      adapterPromise("setMode", async () => {
        await connection.agent.request(acp.methods.agent.session.setMode, { modeId, sessionId })
      }),
    setConfigOption: (sessionId, configId, value) =>
      adapterPromise("setConfigOption", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.setConfigOption, {
          configId,
          sessionId,
          value
        })
        return response.configOptions
      }),
    close: runtimeEffect("close", () => {
      connection.close(new Error(stderr()))
      terminate()
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
    // Auto-approve, matching the Claude/Codex providers' posture (and the old
    // in-app client's behavior). Declining here breaks agents that gate every
    // step on permission — cursor-agent retries denied steps until it gives
    // up with "exceeded max retries".
    .onRequest(acp.methods.client.session.requestPermission, ({ params }) => {
      const options = params.options ?? []
      const allow =
        options.find((option) => option.kind === "allow_always") ??
        options.find((option) => option.kind === "allow_once")
      return allow === undefined
        ? { outcome: { outcome: "cancelled" as const } }
        : { outcome: { optionId: allow.optionId, outcome: "selected" as const } }
    })

export const runtimeEventFromNotification = (
  notification: acp.SessionNotification
): RuntimeEvent => {
  const update = notification.update
  switch (update.sessionUpdate) {
    case "user_message_chunk":
    case "agent_message_chunk":
    case "agent_thought_chunk":
    case "plan":
    case "available_commands_update":
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: update
      }
    case "tool_call":
    case "tool_call_update":
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: withDiffStats(update)
      }
    case "session_info_update":
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

/// ACP adapters deliver diffs only at completion; attach the added/removed
/// line counts so clients can render the +N/−N header without re-diffing.
const withDiffStats = (update: { readonly content?: unknown }): Record<string, unknown> => {
  const content = update.content
  if (!Array.isArray(content)) {
    return update as Record<string, unknown>
  }
  const stats: Array<DiffStat> = []
  for (const block of content) {
    if (
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "diff"
    ) {
      const diff = block as { path?: unknown; oldText?: unknown; newText?: unknown }
      if (typeof diff.path === "string" && typeof diff.newText === "string") {
        stats.push(
          diffStatsFromTexts(
            diff.path,
            typeof diff.oldText === "string" ? diff.oldText : undefined,
            diff.newText
          )
        )
      }
    }
  }
  return stats.length === 0
    ? (update as Record<string, unknown>)
    : { ...(update as Record<string, unknown>), diffStats: stats }
}

const captureStderr = (child: ChildProcessWithoutNullStreams): (() => string) => {
  let buffer = ""
  child.stderr.setEncoding("utf8")
  child.stderr.on("data", (chunk: string) => {
    buffer = `${buffer}${chunk}`.slice(-8192)
  })
  return () => buffer
}
/* v8 ignore stop */

const sessionMetadata = (response: NewSessionResponse): AgentSessionMetadata => ({
  sessionId: response.sessionId,
  ...(response.modes === undefined || response.modes === null
    ? {}
    : { modes: normalizeModeState(response.modes) }),
  configOptions: normalizeConfigOptions(response.configOptions ?? [])
})

const normalizeModeState = (state: AcpSessionModeState): SessionModeState => ({
  currentModeId: state.currentModeId,
  availableModes: state.availableModes.map((mode) => ({
    id: mode.id,
    name: mode.name,
    ...(mode.description === undefined || mode.description === null
      ? {}
      : { description: mode.description })
  }))
})

const normalizeConfigOptions = (
  options: ReadonlyArray<AcpSessionConfigOption>
): ReadonlyArray<SessionConfigOption> =>
  options.flatMap((option) => {
    if (option.type !== "select" || typeof option.currentValue !== "string") {
      return []
    }
    return [
      {
        id: option.id,
        name: option.name,
        ...(option.description === undefined || option.description === null
          ? {}
          : { description: option.description }),
        ...(option.category === undefined || option.category === null
          ? {}
          : { category: option.category }),
        currentValue: option.currentValue,
        options: normalizeSelectOptions(option.options)
      }
    ]
  })

const normalizeSelectOptions = (
  options: ReadonlyArray<AcpSessionConfigSelectOption> | ReadonlyArray<AcpSessionConfigSelectGroup>
): ReadonlyArray<SessionConfigSelectOption> | ReadonlyArray<SessionConfigSelectGroup> => {
  const first = options[0]
  if (first !== undefined && "group" in first) {
    return (options as ReadonlyArray<AcpSessionConfigSelectGroup>).map((group) => ({
      group: group.group,
      name: group.name,
      options: group.options.map(normalizeSelectOption)
    }))
  }
  return (options as ReadonlyArray<AcpSessionConfigSelectOption>).map(normalizeSelectOption)
}

const normalizeSelectOption = (
  option: AcpSessionConfigSelectOption
): SessionConfigSelectOption => ({
  value: option.value,
  name: option.name,
  ...(option.description === undefined || option.description === null
    ? {}
    : { description: option.description })
})
