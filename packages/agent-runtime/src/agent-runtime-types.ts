import type { Harness, HarnessUsageLimits, SessionConfigOption, SessionGoal } from "@codevisor/api"
import { Effect } from "effect"

import type { AgentSessionListOptions, AgentSessionSummary } from "./agent-sessions.js"
import { AgentRuntimeError } from "./types.js"
import type {
  AgentProvider,
  AgentSessionMetadata,
  CancelResult,
  HarnessDefinition,
  HarnessAccountContext,
  HarnessAuthInspection,
  PromptInput,
  PromptResult,
  ProviderEnvironment,
  ProviderId,
  QuestionAnswer,
  RuntimeEventSink,
  SetGoalUpdate
} from "./types.js"

export type ProviderFactory = (environment: ProviderEnvironment) => AgentProvider

export interface AgentRuntimeConfig {
  readonly env?: NodeJS.ProcessEnv
  readonly executableExists?: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable?: (name: string, env: NodeJS.ProcessEnv) => string | undefined
  readonly providerFactories?: ReadonlyArray<ProviderFactory>
  readonly providers?: Partial<Record<ProviderId, AgentProvider>>
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  readonly readVersionOutput?: (path: string, env: NodeJS.ProcessEnv) => Promise<string>
}

export interface AgentRuntimeService {
  readonly catalog: ReadonlyArray<HarnessDefinition>
  readonly discoverHarnesses: Effect.Effect<ReadonlyArray<Harness>, AgentRuntimeError>
  readonly refreshEnvironment: Effect.Effect<void, AgentRuntimeError>
  readonly listAgentSessions: (
    harnessId: string,
    account?: HarnessAccountContext,
    options?: AgentSessionListOptions
  ) => Effect.Effect<ReadonlyArray<AgentSessionSummary>, AgentRuntimeError>
  readonly reconcileConfigValue: (
    harnessId: string,
    option: SessionConfigOption,
    value: string
  ) => string | undefined
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
    toolGateway?: import("./types.js").ToolGatewayConfig,
    sessionOptions?: import("./types.js").CreateSessionOptions
  ) => Effect.Effect<string, AgentRuntimeError>
  readonly inspectHarness: (
    harnessId: string,
    cwd: string,
    account?: HarnessAccountContext,
    configSelections?: Readonly<Record<string, string>>
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly loadAgentSession: (
    harnessId: string,
    agentSessionId: string,
    cwd: string,
    sink: RuntimeEventSink,
    account?: HarnessAccountContext,
    toolGateway?: import("./types.js").ToolGatewayConfig,
    sessionOptions?: import("./types.js").CreateSessionOptions
  ) => Effect.Effect<AgentSessionMetadata, AgentRuntimeError>
  readonly prompt: (
    sessionId: string,
    input: string | PromptInput
  ) => Effect.Effect<PromptResult, AgentRuntimeError>
  readonly cancel: (sessionId: string) => Effect.Effect<CancelResult, AgentRuntimeError>
  readonly loadedAgentSessionIds: () => ReadonlyArray<string>
  readonly closeAgentSession: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (sessionId: string, modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    sessionId: string,
    configId: string,
    value: string
  ) => Effect.Effect<ReadonlyArray<SessionConfigOption>, AgentRuntimeError>
  readonly setGoal: (
    sessionId: string,
    update: SetGoalUpdate
  ) => Effect.Effect<SessionGoal, AgentRuntimeError>
  readonly clearGoal: (sessionId: string) => Effect.Effect<void, AgentRuntimeError>
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
