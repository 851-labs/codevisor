import type { EventKind, Harness, SessionConfigOption, SessionModeState } from "@herdman/api"
import { Effect, Schema } from "effect"

export class AgentRuntimeError extends Schema.TaggedErrorClass<AgentRuntimeError>()(
  "AgentRuntimeError",
  {
    operation: Schema.String,
    message: Schema.String
  }
) {}

export interface RuntimeEvent {
  readonly kind: EventKind
  readonly subjectId: string
  readonly payload: unknown
}

export type RuntimeEventSink = (event: RuntimeEvent) => void | Promise<void>

/// Enqueues an event onto the owning session's serial sink chain. Resolves
/// once the sink has finished processing the event, so providers can flush
/// ordering-sensitive events (turn ends) before resolving a prompt.
export type RuntimeEmit = (event: RuntimeEvent) => Promise<void>

export interface PromptResult {
  readonly stopReason: string
}

export interface AgentSessionMetadata {
  readonly sessionId: string
  readonly modes?: SessionModeState
  readonly configOptions: ReadonlyArray<SessionConfigOption>
}

export type ProviderId = "acp" | "claude" | "codex"

export type HarnessLaunch =
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

export interface HarnessDefinition {
  readonly id: string
  readonly name: string
  readonly symbolName: string
  readonly detectBinaries: ReadonlyArray<string>
  readonly provider: ProviderId
  /// Launch spec for the ACP provider's adapter process; native providers
  /// (claude/codex) drive the detected binary directly and omit it.
  readonly launch?: HarnessLaunch
}

export interface ProviderEnvironment {
  readonly env: NodeJS.ProcessEnv
  readonly executableExists: (name: string, env: NodeJS.ProcessEnv) => boolean
  readonly locateExecutable: (name: string, env: NodeJS.ProcessEnv) => string | undefined
}

/// Per-session control surface returned by a provider. The heavy agent
/// runtime lives in a child process owned by the handle; all session output
/// flows through the `RuntimeEmit` the handle was created with.
export interface AgentSessionHandle {
  readonly prompt: (text: string) => Effect.Effect<PromptResult, AgentRuntimeError>
  readonly cancel: Effect.Effect<void, AgentRuntimeError>
  readonly setMode: (modeId: string) => Effect.Effect<void, AgentRuntimeError>
  readonly setConfigOption: (
    configId: string,
    value: string
  ) => Effect.Effect<void, AgentRuntimeError>
  readonly close: Effect.Effect<void, AgentRuntimeError>
}

export interface CreatedAgentSession {
  readonly metadata: AgentSessionMetadata
  readonly handle: AgentSessionHandle
}

export interface LoadedAgentSession {
  readonly sessionId: string
  readonly handle: AgentSessionHandle
}

export interface AgentProvider {
  readonly id: ProviderId
  readonly readiness: (definition: HarnessDefinition) => Harness["readiness"]
  readonly createSession: (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit
  ) => Effect.Effect<CreatedAgentSession, AgentRuntimeError>
  readonly loadSession: (
    definition: HarnessDefinition,
    agentSessionId: string,
    cwd: string,
    emit: RuntimeEmit
  ) => Effect.Effect<LoadedAgentSession, AgentRuntimeError>
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

export const runtimeError = (operation: string, cause: unknown): AgentRuntimeError =>
  new AgentRuntimeError({
    operation,
    /* v8 ignore next -- local code throws Error values; this keeps external throwables readable. */
    message: cause instanceof Error ? cause.message : String(cause)
  })
