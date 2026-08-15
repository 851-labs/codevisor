import { Effect } from "effect"
import {
  AgentRuntimeError,
  makeAgentRuntime,
  normalizePromptInput,
  type AgentRuntimeConfig,
  type PromptInput,
  type RuntimeEmit,
  type RuntimeEvent
} from "@codevisor/agent-runtime"
import { makeClaudeProvider } from "@codevisor/adapter-claude"
import { makeCodexProvider } from "@codevisor/adapter-codex"
import {
  makeAcpProvider,
  type AcpAgentConnection,
  type AcpConnector,
  type AcpHarnessLaunchRequest
} from "./index.js"

/// The pre-extraction runtime accepted `connector`/`acpAuthProbeTimeoutMs`
/// directly and always registered the acp/claude/codex providers. These tests
/// exercise the runtime *through* real adapters, so this shim recreates that
/// wiring via the providerFactories composition the app uses.
export interface AcpRuntimeTestConfig extends AgentRuntimeConfig {
  readonly connector?: AcpConnector
  readonly acpAuthProbeTimeoutMs?: number
}

export const makeAcpAgentRuntime = ({
  connector,
  acpAuthProbeTimeoutMs,
  ...config
}: AcpRuntimeTestConfig = {}) =>
  makeAgentRuntime({
    ...config,
    providerFactories: [
      (env, context) =>
        makeAcpProvider(env, {
          ...context,
          ...(connector === undefined ? {} : { connector }),
          ...(acpAuthProbeTimeoutMs === undefined
            ? {}
            : { authProbeTimeoutMs: acpAuthProbeTimeoutMs })
        }),
      (env, context) => makeClaudeProvider(env, context),
      (env, context) => makeCodexProvider(env, context)
    ]
  })

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export class FakeConnection implements AcpAgentConnection {
  readonly created: Array<string> = []
  readonly loaded: Array<readonly [string, string]> = []
  readonly prompts: Array<readonly [string, string]> = []
  readonly cancellations: Array<string> = []
  readonly modes: Array<readonly [string, string]> = []
  readonly configs: Array<readonly [string, string, string]> = []
  closeCount = 0
  failClose = false
  agentInfo?: {
    readonly name?: string
    readonly version?: string
    readonly protocolVersion?: number
  }
  readonly listSessions = Effect.succeed([
    { cwd: "/repo", sessionId: "native-session", title: "Harness title" }
  ])

  constructor(
    readonly request: AcpHarnessLaunchRequest,
    readonly emit: RuntimeEmit
  ) {
    this.failClose = request.cwd.includes("fail-close")
  }

  probeAuth(): Effect.Effect<
    {
      readonly state: "notRequired"
      readonly methods: []
      readonly canLogout: false
    },
    AgentRuntimeError
  > {
    if (this.request.env.HANG_AUTH === "1") return Effect.never
    return Effect.succeed({ canLogout: false, methods: [], state: "notRequired" })
  }

  authenticate(_methodId: string): Effect.Effect<void, AgentRuntimeError> {
    return Effect.void
  }

  readonly logout: Effect.Effect<void, AgentRuntimeError> = Effect.void

  createSession(cwd: string): Effect.Effect<
    {
      readonly sessionId: string
      readonly configOptions: []
    },
    AgentRuntimeError
  > {
    if (cwd.includes("hang-inspection")) return Effect.never
    if (cwd.includes("fail-inspection")) {
      return Effect.fail(
        new AgentRuntimeError({ message: "Inspection setup failed", operation: "createSession" })
      )
    }
    return Effect.sync(() => {
      this.created.push(cwd)
      return { configOptions: [], sessionId: `agent-${this.request.harnessId}-1` }
    })
  }

  loadSession(
    sessionId: string,
    cwd: string
  ): Effect.Effect<{ readonly sessionId: string; readonly configOptions: [] }, AgentRuntimeError> {
    return Effect.sync(() => {
      this.loaded.push([sessionId, cwd])
      return { configOptions: [], sessionId }
    })
  }

  prompt(
    sessionId: string,
    input: string | PromptInput
  ): Effect.Effect<{ readonly stopReason: string }, AgentRuntimeError> {
    return Effect.promise(async () => {
      const { text } = normalizePromptInput(input)
      this.prompts.push([sessionId, text])
      await this.emit(conversationEvent(sessionId, "user", text))
      await this.emit(conversationEvent(sessionId, "assistant", `Echo: ${text}`))
      return { stopReason: "end_turn" }
    })
  }

  cancel(sessionId: string): Effect.Effect<void, AgentRuntimeError> {
    return Effect.sync(() => {
      this.cancellations.push(sessionId)
    })
  }

  setMode(sessionId: string, modeId: string): Effect.Effect<void, AgentRuntimeError> {
    return Effect.sync(() => {
      this.modes.push([sessionId, modeId])
    })
  }

  setConfigOption(
    sessionId: string,
    configId: string,
    value: string
  ): Effect.Effect<unknown, AgentRuntimeError> {
    return Effect.sync(() => {
      this.configs.push([sessionId, configId, value])
      return [{ currentValue: value, id: configId }]
    })
  }

  readonly close: Effect.Effect<void, AgentRuntimeError> = Effect.sync(() => {
    this.closeCount += 1
    if (this.failClose) {
      throw new Error("close failed")
    }
  })
}

export const makeConnector = (): AcpConnector & {
  readonly connections: ReadonlyArray<FakeConnection>
  readonly requests: ReadonlyArray<AcpHarnessLaunchRequest>
} => {
  const connections: Array<FakeConnection> = []
  const requests: Array<AcpHarnessLaunchRequest> = []
  return {
    connections,
    requests,
    connect: (request, emit) =>
      Effect.sync(() => {
        requests.push(request)
        const connection = new FakeConnection(request, emit)
        connections.push(connection)
        return connection
      })
  }
}

export const conversationEvent = (
  sessionId: string,
  role: "user" | "assistant",
  text: string
): RuntimeEvent => ({
  kind: "session.output",
  payload: { role, text },
  subjectId: sessionId
})
