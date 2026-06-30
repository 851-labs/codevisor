import type { EventEnvelope, EventKind, Harness } from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import * as acp from "@agentclientprotocol/sdk"
import { Context, Effect, Layer, Schema } from "effect"
import { accessSync, constants } from "node:fs"
import { randomUUID } from "node:crypto"

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
  readonly stopReason: "end_turn" | "cancelled" | "error"
  readonly events: ReadonlyArray<RuntimeEvent>
}

export interface AcpRuntimeConfig {
  readonly env?: NodeJS.ProcessEnv
  readonly executableExists?: (name: string, env: NodeJS.ProcessEnv) => boolean
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
  readonly launchKind: Harness["launchKind"]
  readonly runner?: string
}

const catalog: ReadonlyArray<HarnessDefinition> = [
  {
    id: "claude-code",
    name: "Claude Code",
    symbolName: "sparkle",
    detectBinaries: ["claude"],
    launchKind: "npx",
    runner: "npx"
  },
  {
    id: "codex",
    name: "Codex",
    symbolName: "chevron.left.forwardslash.chevron.right",
    detectBinaries: ["codex"],
    launchKind: "npx",
    runner: "npx"
  },
  {
    id: "gemini",
    name: "Gemini CLI",
    symbolName: "diamond",
    detectBinaries: ["gemini"],
    launchKind: "npx",
    runner: "npx"
  },
  {
    id: "opencode",
    name: "OpenCode",
    symbolName: "curlybraces",
    detectBinaries: ["opencode"],
    launchKind: "executable"
  },
  {
    id: "goose",
    name: "goose",
    symbolName: "bird",
    detectBinaries: ["goose"],
    launchKind: "executable"
  }
]

export const makeAcpRuntime = (config: AcpRuntimeConfig = {}): AcpRuntimeService => {
  const env = config.env ?? process.env
  const executableExists = config.executableExists ?? executableExistsOnPath
  const sessions = new Map<string, { readonly harnessId: string; readonly cwd: string }>()

  return {
    discoverHarnesses: Effect.succeed(discover(catalog, env, executableExists)),
    createAgentSession: (harnessId, cwd) =>
      runtimeAttempt("createAgentSession", () => {
        const agentSessionId = `agent_${randomUUID()}`
        sessions.set(agentSessionId, { harnessId, cwd })
        return agentSessionId
      }),
    loadAgentSession: (harnessId, agentSessionId, cwd) =>
      runtimeAttempt("loadAgentSession", () => {
        sessions.set(agentSessionId, { harnessId, cwd })
        return agentSessionId
      }),
    prompt: (sessionId, text) =>
      runtimeAttempt("prompt", () => ({
        stopReason: "end_turn",
        events: [
          {
            kind: "session.output",
            subjectId: sessionId,
            payload: {
              role: "user",
              text,
              receivedAt: isoTimestamp()
            }
          },
          {
            kind: "session.output",
            subjectId: sessionId,
            payload: {
              role: "assistant",
              text: `Queued prompt for ACP session ${sessionId}.`,
              protocolVersion: acpProtocolVersion
            }
          }
        ]
      })),
    cancel: (sessionId) =>
      Effect.succeed({
        kind: "session.updated",
        subjectId: sessionId,
        payload: { stopReason: "cancelled" }
      }),
    setMode: (sessionId, modeId) =>
      Effect.succeed({
        kind: "session.updated",
        subjectId: sessionId,
        payload: { modeId }
      }),
    setConfigOption: (sessionId, configId, value) =>
      Effect.succeed({
        kind: "session.updated",
        subjectId: sessionId,
        payload: { configId, value }
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

const runtimeAttempt = <A>(operation: string, run: () => A): Effect.Effect<A, AcpRuntimeError> =>
  Effect.try({
    try: run,
    /* v8 ignore next -- current in-memory ACP operations do not expose a public throwing path. */
    catch: (cause) =>
      new AcpRuntimeError({
        operation,
        message: cause instanceof Error ? cause.message : String(cause)
      })
  })

const discover = (
  definitions: ReadonlyArray<HarnessDefinition>,
  env: NodeJS.ProcessEnv,
  executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean
): ReadonlyArray<Harness> =>
  definitions.map((definition) => {
    const installed = definition.detectBinaries.some((binary) => executableExists(binary, env))
    const runnerReady = definition.runner === undefined || executableExists(definition.runner, env)
    return {
      id: definition.id,
      name: definition.name,
      symbolName: definition.symbolName,
      source: "registry",
      launchKind: definition.launchKind,
      enabled: true,
      readiness:
        installed && runnerReady
          ? { state: "ready" }
          : {
              state: "unavailable",
              detail: installed ? `Requires ${definition.runner}` : "CLI not found on PATH"
            }
    }
  })

const executableExistsOnPath = (name: string, env: NodeJS.ProcessEnv): boolean => {
  const path = env.PATH ?? ""
  for (const directory of path.split(":")) {
    try {
      accessSync(`${directory}/${name}`, constants.X_OK)
      return true
    } catch {
      continue
    }
  }
  return false
}
