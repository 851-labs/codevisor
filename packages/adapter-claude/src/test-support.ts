import { EventEmitter } from "node:events"
import type {
  Options as ClaudeOptions,
  SDKMessage,
  SDKUserMessage
} from "@anthropic-ai/claude-agent-sdk"
import { Effect } from "effect"
import type { HarnessDefinition, ProviderEnvironment } from "@codevisor/agent-runtime"
import { makeClaudeProvider, type ClaudeProviderConfig } from "./claude.js"

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const definition: HarnessDefinition = {
  detectBinaries: ["claude"],
  id: "claude-code",
  name: "Claude Code",
  provider: "claude",
  symbolName: "sparkle"
}

export const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  executableExists: (name) => name === "claude",
  locateExecutable: (name) => (name === "claude" ? "/bin/claude" : undefined)
}

/// A controllable SDK Query: tests push scripted SDKMessages and observe the
/// streaming-input prompt the provider writes into.
export class FakeQuery {
  private readonly changes = new EventEmitter()
  private pushed = 0
  private reads = 0
  private inputCount = 0

  changed(): void {
    this.changes.emit("change")
  }

  async waitFor(predicate: () => boolean): Promise<void> {
    while (true) {
      const next = Promise.withResolvers<void>()
      const listener = () => next.resolve()
      this.changes.once("change", listener)
      try {
        if (predicate()) return
        await next.promise
      } finally {
        this.changes.off("change", listener)
      }
    }
  }

  async drain(): Promise<void> {
    await this.waitFor(() => this.reads > this.pushed)
  }

  async nextPrompt(): Promise<void> {
    this.inputCount += 1
    await this.waitFor(() => this.userMessages.length >= this.inputCount)
  }

  private buffer: Array<SDKMessage> = []
  private failure: unknown
  private waiting:
    | {
        readonly reject: (cause: unknown) => void
        readonly resolve: (result: IteratorResult<SDKMessage>) => void
      }
    | undefined
  private ended = false
  readonly interrupts: Array<number> = []
  readonly permissionModes: Array<string> = []
  readonly models: Array<string | undefined> = []
  readonly flagSettings: Array<Record<string, unknown>> = []
  promptInput: AsyncIterable<SDKUserMessage> | undefined
  options: ClaudeOptions | undefined
  readonly userMessages: Array<SDKUserMessage> = []
  interruptImplementation: (() => Promise<void>) | undefined

  push(message: SDKMessage): void {
    this.pushed += 1
    const waiting = this.waiting
    if (waiting !== undefined) {
      this.waiting = undefined
      waiting.resolve({ done: false, value: message })
      return
    }
    this.buffer.push(message)
  }

  finish(): void {
    this.ended = true
    this.waiting?.resolve({ done: true, value: undefined })
    this.waiting = undefined
  }

  fail(cause: unknown): void {
    this.ended = true
    const waiting = this.waiting
    this.waiting = undefined
    if (waiting === undefined) {
      this.failure = cause
    } else {
      waiting.reject(cause)
    }
  }

  async interrupt(): Promise<void> {
    this.interrupts.push(Date.now())
    this.changed()
    await this.interruptImplementation?.()
  }

  async setPermissionMode(mode: string): Promise<void> {
    this.permissionModes.push(mode)
  }

  async setModel(model?: string): Promise<void> {
    this.models.push(model)
  }

  async applyFlagSettings(settings: Record<string, unknown>): Promise<void> {
    this.flagSettings.push(settings)
  }

  async supportedModels(): Promise<
    Array<{
      value: string
      displayName: string
      description: string
      supportsEffort?: boolean
      supportedEffortLevels?: Array<string>
      supportsFastMode?: boolean
    }>
  > {
    return [
      {
        description: "",
        displayName: "Fable 5",
        supportedEffortLevels: ["low", "medium", "high", "xhigh"],
        supportsEffort: true,
        supportsFastMode: true,
        value: "claude-fable-5"
      },
      { description: "", displayName: "Opus 4.8", value: "claude-opus-4-8" }
    ]
  }

  [Symbol.asyncIterator](): AsyncIterator<SDKMessage> {
    return {
      next: (): Promise<IteratorResult<SDKMessage>> => {
        this.reads += 1
        this.changed()
        if (this.failure !== undefined) {
          const failure = this.failure
          this.failure = undefined
          return Promise.reject(failure)
        }
        const buffered = this.buffer.shift()
        if (buffered !== undefined) {
          return Promise.resolve({ done: false, value: buffered })
        }
        if (this.ended) {
          return Promise.resolve({ done: true, value: undefined })
        }
        return new Promise((resolvePromise, rejectPromise) => {
          this.waiting = { reject: rejectPromise, resolve: resolvePromise }
        })
      }
    }
  }
}

export const initMessage = (sessionId = "sdk-session-1", model = "claude-fable-5"): SDKMessage =>
  ({
    apiKeySource: "none",
    cwd: "/tmp",
    model,
    session_id: sessionId,
    subtype: "init",
    type: "system"
  }) as never

export const resultMessage = (
  subtype: "success" | "error_during_execution" = "success"
): SDKMessage =>
  ({
    duration_ms: 10,
    errors: subtype === "success" ? [] : ["boom"],
    is_error: subtype !== "success",
    num_turns: 1,
    result: "done",
    session_id: "sdk-session-1",
    subtype,
    type: "result"
  }) as never

/// A result message with an explicit `stop_reason` — for the truncation
/// (`max_tokens`) auto-continue path, which keys off it.
export const resultWith = (fields: {
  subtype?: "success" | "error_during_execution"
  stop_reason?: string | null
  is_error?: boolean
  result?: string
  errors?: string[]
}): SDKMessage => {
  const subtype = fields.subtype ?? "success"
  return {
    duration_ms: 10,
    errors: fields.errors ?? (subtype === "success" ? [] : ["boom"]),
    is_error: fields.is_error ?? subtype !== "success",
    num_turns: 1,
    result: fields.result ?? "done",
    session_id: "sdk-session-1",
    stop_reason: fields.stop_reason ?? "end_turn",
    subtype,
    type: "result"
  } as never
}

/// An assistant message carrying the SDK's per-message `error` (overloaded,
/// authentication_failed, …) — the signal the provider uses to tell a transient
/// failure (retry) from a permanent one (surface).
export const assistantErrorMessage = (error: string): SDKMessage =>
  ({
    error,
    message: { content: [], id: "msg-err", role: "assistant" },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "assistant",
    uuid: "00000000-0000-0000-0000-000000000002"
  }) as never

/// A 529-style transient failure that arrives with NO structured error — the CLI
/// renders it as an assistant text message ending on a stop sequence.
export const assistantApiErrorMessage = (text: string): SDKMessage =>
  ({
    message: {
      content: [{ text, type: "text" }],
      id: "msg-apierr",
      role: "assistant",
      stop_reason: "stop_sequence"
    },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "assistant",
    uuid: "00000000-0000-0000-0000-000000000003"
  }) as never

export const rateLimitEvent = (rateLimitInfo: Record<string, unknown>): SDKMessage =>
  ({
    rate_limit_info: rateLimitInfo,
    session_id: "sdk-session-1",
    type: "rate_limit_event",
    uuid: "00000000-0000-0000-0000-000000000004"
  }) as never

export const streamEvent = (event: unknown, parentToolUseId: string | null = null): SDKMessage =>
  ({
    event,
    parent_tool_use_id: parentToolUseId,
    session_id: "sdk-session-1",
    type: "stream_event",
    uuid: "00000000-0000-0000-0000-000000000000"
  }) as never

export const systemMessage = (subtype: string, fields: Record<string, unknown>): SDKMessage =>
  ({
    session_id: "sdk-session-1",
    subtype,
    type: "system",
    uuid: "00000000-0000-0000-0000-000000000001",
    ...fields
  }) as never

export const makeProvider = (
  fake: FakeQuery,
  checkVersion = async () => "2.1.0",
  getSessionInfo?: NonNullable<ClaudeProviderConfig["getSessionInfo"]>,
  extra: Partial<ClaudeProviderConfig> = {}
) =>
  makeClaudeProvider(environment, {
    ...extra,
    checkVersion,
    ...(getSessionInfo === undefined ? {} : { getSessionInfo }),
    queryFn: (input) => {
      fake.promptInput = input.prompt
      fake.options = input.options
      void (async () => {
        for await (const message of input.prompt) {
          fake.userMessages.push(message)
          fake.changed()
        }
      })()
      return fake as never
    },
    readFile: (path) => (path === "/tmp/existing.txt" ? "line1\nline2\nline3\n" : undefined)
  })
