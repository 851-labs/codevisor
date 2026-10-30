import type {
  EventKind,
  GoalStatus,
  Harness,
  HarnessUsageLimits,
  QuestionAnswerEntry,
  SessionConfigOption,
  SessionContext,
  SessionGoal,
  SessionModeState,
  SessionSkills
} from "@codevisor/api"
import { isRecord } from "@codevisor/api"
import { Effect, Schema } from "effect"

import type { HarnessDefinition, ProviderId } from "./harness-definition-types.js"

export class AgentRuntimeError extends Schema.TaggedErrorClass<AgentRuntimeError>()(
  "AgentRuntimeError",
  {
    operation: Schema.String,
    message: Schema.String,
    authRequired: Schema.optional(Schema.Boolean),
    conversationMissing: Schema.optional(Schema.Boolean)
  }
) {}

export interface RuntimeEvent {
  readonly kind: EventKind
  readonly subjectId: string
  readonly payload: unknown
}

export type RuntimeEventSink = (event: RuntimeEvent) => void | Promise<void>

export type RuntimeEmit = (event: RuntimeEvent) => Promise<void>

export interface PromptResult {
  readonly stopReason: string
}

export interface CancelResult {
  readonly runtimeState: "reusable" | "retire"
  readonly resumesInterruptedTurn?: boolean
}

export interface InterruptedTurnResume {
  readonly notice: string
  readonly stoppedTasks: ReadonlyArray<string>
}

export interface PromptAttachmentInput {
  readonly name: string
  readonly mimeType: string
  readonly kind: "image" | "file"
  readonly sizeBytes: number
  readonly path: string
  readonly inline?: { readonly mimeType: string; readonly data: Buffer }
  readonly inlineOmitted?: boolean
}

export interface PromptInput {
  readonly text: string
  readonly attachments?: ReadonlyArray<PromptAttachmentInput>
}

export const normalizePromptInput = (input: string | PromptInput): PromptInput =>
  typeof input === "string" ? { text: input } : input

export interface AgentSessionMetadata {
  readonly sessionId: string
  readonly modes?: SessionModeState
  readonly configOptions: ReadonlyArray<SessionConfigOption>
  readonly supportsGoals?: boolean
  readonly supportsSteering?: boolean
  readonly skills?: SessionSkills
  readonly unappliedConfigSelections?: Readonly<Record<string, string>>
}

export interface SetGoalUpdate {
  readonly objective?: string
  readonly status?: GoalStatus
  readonly tokenBudget?: number | null
}

export interface QuestionAnswer {
  readonly outcome: "answered" | "cancelled"
  readonly answers?: Readonly<Record<string, QuestionAnswerEntry>>
}

export type {
  ProviderId,
  HarnessLaunch,
  HarnessLaunchFile,
  TrustFlag,
  InstallOrigin,
  HarnessInstallMethodSpec,
  UpdateCheckSpec,
  UpdateApplySpec,
  HarnessUpdateSource,
  NativeMcpConfigSpec,
  HarnessSkillsSpec,
  HarnessDefinition
} from "./harness-definition-types.js"

export type FlagSupport = (
  command: string,
  flag: import("./harness-definition-types.js").TrustFlag,
  env: NodeJS.ProcessEnv
) => Promise<boolean>

export interface ProviderEnvironment {
  readonly env: NodeJS.ProcessEnv
  readonly envFor: (cwd: string) => Promise<NodeJS.ProcessEnv>
  readonly executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable: (name: string, env: NodeJS.ProcessEnv) => string | undefined
  readonly supportsFlag?: FlagSupport
}

export const withoutEnv = (
  env: Readonly<NodeJS.ProcessEnv>,
  unset: ReadonlyArray<string> | undefined
): NodeJS.ProcessEnv => {
  if (unset === undefined || unset.length === 0) return env
  const result: NodeJS.ProcessEnv = { ...env }
  for (const name of unset) delete result[name]
  return result
}

export interface HarnessAccountContext {
  readonly id: string
  readonly profileKind: "default" | "managed"
  readonly env?: Readonly<Record<string, string>>
  readonly unsetEnv?: ReadonlyArray<string>
  readonly beforeTurn?: () => Promise<void>
  readonly oauth?: {
    readonly token: (rejectedAccessToken?: string) => Promise<{
      readonly accessToken: string
      readonly accountId?: string
      readonly planType?: string
    }>
  }
}

export interface ToolGatewayConfig {
  readonly name: string
  readonly url: string
  readonly bearerToken: string
}

export interface HarnessAuthInspection {
  readonly state: "authenticated" | "unauthenticated" | "notRequired" | "error"
  readonly methods: ReadonlyArray<{
    readonly id: string
    readonly name: string
    readonly description?: string
  }>
  readonly canLogout: boolean
  readonly detail?: string
  readonly label?: string
}

export interface AgentSessionHandle {
  readonly resumable?: boolean
  readonly prompt: (input: string | PromptInput) => Effect.Effect<PromptResult, AgentRuntimeError>
  readonly steer?: (input: string | PromptInput) => Effect.Effect<boolean, AgentRuntimeError>
  readonly cancel: Effect.Effect<CancelResult, AgentRuntimeError>
  readonly pauseForRestart?: Effect.Effect<CancelResult, AgentRuntimeError>
  readonly setMode: (modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    configId: string,
    value: string
  ) => Effect.Effect<ReadonlyArray<SessionConfigOption>, AgentRuntimeError>
  readonly setGoal?: (update: SetGoalUpdate) => Effect.Effect<SessionGoal, AgentRuntimeError>
  readonly clearGoal?: Effect.Effect<void, AgentRuntimeError>
  readonly answerQuestion?: (
    questionId: string,
    answer: QuestionAnswer
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly replyToQuestion?: (
    questionId: string,
    reply: PromptInput
  ) => Effect.Effect<boolean, AgentRuntimeError>
  readonly readContext?: Effect.Effect<SessionContext | undefined, AgentRuntimeError>
  readonly close: Effect.Effect<void, AgentRuntimeError>
}

export interface CreatedAgentSession {
  readonly metadata: AgentSessionMetadata
  readonly handle: AgentSessionHandle
}

export interface LoadedAgentSession {
  readonly sessionId: string
  readonly handle: AgentSessionHandle
  readonly metadata?: AgentSessionMetadata
}

export interface CreateSessionOptions {
  readonly modelListTimeoutMs?: number
  readonly skillListTimeoutMs?: number
  readonly configSelections?: Readonly<Record<string, string>>
  readonly bot?: boolean
  readonly forkFrom?: string
  readonly resumeInterruptedTurn?: InterruptedTurnResume
}

export interface AgentProvider {
  readonly id: ProviderId
  readonly readiness: (definition: HarnessDefinition) => Harness["readiness"]
  readonly createSession: (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig,
    sessionOptions?: CreateSessionOptions
  ) => Effect.Effect<CreatedAgentSession, AgentRuntimeError>
  readonly loadSession: (
    definition: HarnessDefinition,
    agentSessionId: string,
    cwd: string,
    emit: RuntimeEmit,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig,
    sessionOptions?: CreateSessionOptions
  ) => Effect.Effect<LoadedAgentSession, AgentRuntimeError>
  readonly listAgentSessions?: (
    definition: HarnessDefinition,
    account?: HarnessAccountContext,
    options?: import("./agent-sessions.js").AgentSessionListOptions
  ) => Promise<ReadonlyArray<import("./agent-sessions.js").AgentSessionSummary>>
  readonly reconcileConfigValue?: (option: SessionConfigOption, value: string) => string | undefined
  readonly readUsageLimits?: (
    definition: HarnessDefinition,
    cwd: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<HarnessUsageLimits, AgentRuntimeError>
  readonly probeAuth?: (
    definition: HarnessDefinition,
    account?: HarnessAccountContext
  ) => Effect.Effect<HarnessAuthInspection, AgentRuntimeError>
  readonly authenticate?: (
    definition: HarnessDefinition,
    methodId: string,
    account?: HarnessAccountContext
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly logout?: (
    definition: HarnessDefinition,
    account?: HarnessAccountContext
  ) => Effect.Effect<void, AgentRuntimeError>
}

export const runtimeEffect = <A>(
  operation: string,
  run: () => A
): Effect.Effect<A, AgentRuntimeError> =>
  Effect.try({
    try: run,
    catch: (cause) => runtimeError(operation, cause)
  })

export const adapterPromise = <A>(
  operation: string,
  run: () => Promise<A>
): Effect.Effect<A, AgentRuntimeError> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => runtimeError(operation, cause)
  })

const requiresSignIn = (cause: unknown): boolean =>
  isRecord(cause) &&
  (cause.authRequired === true ||
    cause.code === -32000 ||
    cause.kind === "authRequired" ||
    cause.reason === "reauthenticate" ||
    cause.reason === "revoked")

export const runtimeError = (operation: string, cause: unknown): AgentRuntimeError =>
  new AgentRuntimeError({
    operation,
    /* v8 ignore next */
    message: cause instanceof Error ? cause.message : String(cause),
    ...(requiresSignIn(cause) ? { authRequired: true } : {}),
    ...(isRecord(cause) && cause.conversationMissing === true ? { conversationMissing: true } : {})
  })
