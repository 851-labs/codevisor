import * as acp from "@agentclientprotocol/sdk"
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
import type { SessionConfigOption, SessionGoal, TurnStopKind } from "@codevisor/api"
import { Effect } from "effect"

export const acpClientCapabilities = (): acp.ClientCapabilities => ({
  plan: {},
  terminal: false
})

export interface AcpHarnessLaunchRequest {
  readonly harnessId: string
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

export interface AcpPromptResult {
  readonly stopReason: string
  readonly stopDetail?: string
  readonly stopKind?: TurnStopKind
  readonly resetsAt?: string
  readonly retryable?: boolean
}

export interface AcpAgentConnection {
  readonly canLoadSession?: boolean
  readonly listSessions?: Effect.Effect<ReadonlyArray<AgentSessionSummary>, AgentRuntimeError>
  readonly createSession: (
    cwd: string,
    toolGateway?: ToolGatewayConfig,
    skillListTimeoutMs?: number
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly loadSession: (
    sessionId: string,
    cwd: string,
    toolGateway?: ToolGatewayConfig,
    skillListTimeoutMs?: number
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly prompt: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<AcpPromptResult, AgentRuntimeError>
  readonly steer?: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<boolean, AgentRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<ReadonlyArray<SessionConfigOption>, AgentRuntimeError>
  readonly setGoal?: (
    sessionId: string,
    update: SetGoalUpdate
  ) => Effect.Effect<SessionGoal, AgentRuntimeError>
  readonly clearGoal?: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly answerQuestion?: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly replyToQuestion?: (
    sessionId: string,
    questionId: string,
    reply: PromptInput
  ) => Effect.Effect<boolean, AgentRuntimeError>
  readonly probeAuth: (cwd: string) => Effect.Effect<
    {
      readonly state: "authenticated" | "unauthenticated" | "notRequired" | "error"
      readonly methods: ReadonlyArray<{
        readonly id: string
        readonly name: string
        readonly description?: string
        readonly external?: boolean
      }>
      readonly canLogout: boolean
      readonly detail?: string
    },
    AgentRuntimeError
  >
  readonly authenticate: (methodId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly logout: Effect.Effect<void, AgentRuntimeError>
  readonly extRequest?: (
    method: string,
    params: Record<string, unknown>
  ) => Effect.Effect<unknown, AgentRuntimeError>
  readonly close: Effect.Effect<void, AgentRuntimeError>
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
