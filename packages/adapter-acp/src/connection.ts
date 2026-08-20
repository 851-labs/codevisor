import * as acp from "@agentclientprotocol/sdk"
import { Effect } from "effect"
import type {
  AgentRuntimeError,
  AgentSessionMetadata,
  AgentSessionSummary,
  PromptInput,
  QuestionAnswer,
  RuntimeEmit,
  SetGoalUpdate,
  ToolGatewayConfig
} from "@codevisor/agent-runtime"
import type { SessionGoal } from "@codevisor/api"

export const acpProtocolVersion = acp.PROTOCOL_VERSION

export const acpClientCapabilities = (terminal: boolean): acp.ClientCapabilities => ({
  plan: {},
  terminal
})

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
  readonly listSessions?: Effect.Effect<ReadonlyArray<AgentSessionSummary>, AgentRuntimeError>
  readonly createSession: (
    cwd: string,
    toolGateway?: ToolGatewayConfig
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly loadSession: (
    sessionId: string,
    cwd: string,
    toolGateway?: ToolGatewayConfig
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly prompt: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<
    {
      readonly stopReason: string
      readonly stopDetail?: string
      readonly retryable?: boolean
    },
    AgentRuntimeError
  >
  readonly cancel: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  /// Returns the agent's updated config options in Codevisor's normalized
  /// shape so the caller can broadcast them.
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<unknown, AgentRuntimeError>
  readonly setGoal?: (
    sessionId: string,
    update: SetGoalUpdate
  ) => Effect.Effect<SessionGoal, AgentRuntimeError>
  readonly clearGoal?: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  /// Resolves a pending `session/request_permission` that was surfaced as a
  /// blocking question. Absent on connections without permission plumbing
  /// (fakes, older transports) — the runtime then reports unsupported.
  readonly answerQuestion?: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly probeAuth: (cwd: string) => Effect.Effect<
    {
      readonly state: "authenticated" | "unauthenticated" | "notRequired" | "error"
      readonly methods: ReadonlyArray<{
        readonly id: string
        readonly name: string
        readonly description?: string
      }>
      readonly canLogout: boolean
      readonly detail?: string
    },
    AgentRuntimeError
  >
  readonly authenticate: (methodId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly logout: Effect.Effect<void, AgentRuntimeError>
  readonly close: Effect.Effect<void, AgentRuntimeError>
  /// What the agent reported during the ACP initialize handshake. Absent on
  /// connections whose transport predates the field (fakes, older adapters).
  readonly agentInfo?: {
    readonly name?: string
    readonly version?: string
    readonly protocolVersion?: number
  }
}

export interface AcpConnector {
  readonly connect: (
    request: AcpHarnessLaunchRequest,
    emit: RuntimeEmit
  ) => Effect.Effect<AcpAgentConnection, AgentRuntimeError>
}
