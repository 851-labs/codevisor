import { EventEmitter } from "node:events"

import type {
  CanUseTool,
  ModelInfo,
  Options as ClaudeOptions,
  SDKControlGetContextUsageResponse,
  SDKControlInitializeResponse,
  SDKMessage,
  SDKUserMessage
} from "@anthropic-ai/claude-agent-sdk"
import type { HarnessDefinition, ProviderEnvironment, RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import { isRecord } from "./internal.js"
import { makeClaudeProvider, type ClaudeProviderConfig } from "./provider.js"
import type { ClaudeSlashCommand } from "./skills.js"
import type { SubagentTranscripts } from "./subagent-transcripts.js"

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
  envFor: () => Promise.resolve(environment.env),
  executableExists: (name) => name === "claude",
  locateExecutable: (name) => (name === "claude" ? "/bin/claude" : undefined)
}

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
  readonly controlRequests: Array<Record<string, unknown>> = []
  readonly permissionModes: Array<string> = []
  readonly models: Array<string | undefined> = []
  readonly flagSettings: Array<Record<string, unknown>> = []
  promptInput: AsyncIterable<SDKUserMessage> | undefined
  options: ClaudeOptions | undefined
  readonly successors: Array<FakeQuery> = []
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

  async interrupt(): Promise<undefined> {
    this.interrupts.push(Date.now())
    this.changed()
    await this.interruptImplementation?.()
    return undefined
  }

  async request(request: Record<string, unknown>): Promise<undefined> {
    this.controlRequests.push(request)
    this.changed()
    return undefined
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

  async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(): Promise<never> {
    throw new Error("Claude usage is unavailable")
  }

  contextUsage: SDKControlGetContextUsageResponse | undefined

  async getContextUsage(): Promise<SDKControlGetContextUsageResponse> {
    if (this.contextUsage === undefined) throw new Error("Claude context usage is unavailable")
    return this.contextUsage
  }

  commands: Array<ClaudeSlashCommand> = []

  async supportedCommands(): Promise<Array<ClaudeSlashCommand>> {
    return this.commands
  }

  initializationFailure: unknown = undefined

  async initializationResult(): Promise<SDKControlInitializeResponse> {
    if (this.initializationFailure !== undefined) throw this.initializationFailure
    return {
      account: {},
      agents: [],
      available_output_styles: [],
      commands: [],
      models: [],
      output_style: "default"
    }
  }

  async supportedModels(): Promise<Array<ModelInfo>> {
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

export interface SDKMessageFixture {
  readonly type: SDKMessage["type"]
  readonly [field: string]: unknown
}

export const sdkMessage = (fixture: SDKMessageFixture): SDKMessage => {
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion
  return fixture as SDKMessage
}

export const recordValue = (value: unknown): Record<string, unknown> => {
  if (!isRecord(value)) throw new Error(`Expected an object, got ${JSON.stringify(value)}`)
  return value
}

export const recordsValue = (value: unknown): Array<Record<string, unknown>> => {
  if (!Array.isArray(value)) throw new Error(`Expected an array, got ${JSON.stringify(value)}`)
  return value.map(recordValue)
}

export const stringValue = (value: unknown): string => {
  if (typeof value !== "string") throw new Error(`Expected a string, got ${JSON.stringify(value)}`)
  return value
}

export const payloadOf = (event: RuntimeEvent | undefined): Record<string, unknown> =>
  recordValue(event?.payload)

export const toolCheck = (): Parameters<CanUseTool>[2] => ({
  requestId: "request-1",
  signal: new AbortController().signal,
  toolUseID: "tool-use-1"
})

export const initMessage = (sessionId = "sdk-session-1", model = "claude-fable-5"): SDKMessage =>
  sdkMessage({
    apiKeySource: "none",
    cwd: "/tmp",
    model,
    session_id: sessionId,
    subtype: "init",
    type: "system"
  })

export const resultMessage = (
  subtype: "success" | "error_during_execution" = "success"
): SDKMessage =>
  sdkMessage({
    duration_ms: 10,
    errors: subtype === "success" ? [] : ["boom"],
    is_error: subtype !== "success",
    num_turns: 1,
    result: "done",
    session_id: "sdk-session-1",
    subtype,
    type: "result"
  })

export const resultWith = (fields: {
  subtype?: "success" | "error_during_execution"
  stop_reason?: string | null
  is_error?: boolean
  result?: string
  errors?: string[]
}): SDKMessage => {
  const subtype = fields.subtype ?? "success"
  return sdkMessage({
    duration_ms: 10,
    errors: fields.errors ?? (subtype === "success" ? [] : ["boom"]),
    is_error: fields.is_error ?? subtype !== "success",
    num_turns: 1,
    result: fields.result ?? "done",
    session_id: "sdk-session-1",
    stop_reason: fields.stop_reason ?? "end_turn",
    subtype,
    type: "result"
  })
}

export const assistantErrorMessage = (error: string): SDKMessage =>
  sdkMessage({
    error,
    message: { content: [], id: "msg-err", role: "assistant" },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "assistant",
    uuid: "00000000-0000-0000-0000-000000000002"
  })

export const assistantApiErrorMessage = (text: string): SDKMessage =>
  sdkMessage({
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
  })

export const rateLimitEvent = (rateLimitInfo: Record<string, unknown>): SDKMessage =>
  sdkMessage({
    rate_limit_info: rateLimitInfo,
    session_id: "sdk-session-1",
    type: "rate_limit_event",
    uuid: "00000000-0000-0000-0000-000000000004"
  })

export const streamEvent = (event: unknown, parentToolUseId: string | null = null): SDKMessage =>
  sdkMessage({
    event,
    parent_tool_use_id: parentToolUseId,
    session_id: "sdk-session-1",
    type: "stream_event",
    uuid: "00000000-0000-0000-0000-000000000000"
  })

export const systemMessage = (subtype: string, fields: Record<string, unknown>): SDKMessage =>
  sdkMessage({
    session_id: "sdk-session-1",
    subtype,
    type: "system",
    uuid: "00000000-0000-0000-0000-000000000001",
    ...fields
  })

const NO_SUBAGENT_TRANSCRIPTS: SubagentTranscripts = {
  locate: () => undefined,
  readLines: (_path, offset) => ({ offset, text: "" })
}

export const makeProvider = (
  fake: FakeQuery,
  checkVersion = async () => "2.1.0",
  getSessionInfo?: NonNullable<ClaudeProviderConfig["getSessionInfo"]>,
  extra: Partial<ClaudeProviderConfig> = {}
) =>
  makeClaudeProvider(environment, {
    subagentTranscripts: () => NO_SUBAGENT_TRANSCRIPTS,
    ...extra,
    checkVersion,
    ...(getSessionInfo === undefined ? {} : { getSessionInfo }),
    queryFn: (input) => {
      const target = fake.promptInput === undefined ? fake : (fake.successors.shift() ?? fake)
      target.promptInput = input.prompt
      target.options = input.options
      void (async () => {
        for await (const message of input.prompt) {
          target.userMessages.push(message)
          target.changed()
        }
      })()
      return target
    },
    readFile: (path) => (path === "/tmp/existing.txt" ? "line1\nline2\nline3\n" : undefined)
  })

export const startTestSession = async () => {
  const fake = new FakeQuery()
  const provider = makeProvider(fake)
  const events: Array<RuntimeEvent> = []
  const emit = async (event: RuntimeEvent): Promise<void> => {
    events.push(event)
  }
  const createPromise = run(provider.createSession(definition, "/tmp", emit))
  fake.push(initMessage())
  const created = await createPromise
  return { fake, events, created }
}

type SupportedModels = Awaited<ReturnType<FakeQuery["supportedModels"]>>

export const RELEASE_MODELS: SupportedModels = [
  {
    description: "",
    displayName: "Sonnet",
    supportedEffortLevels: ["low", "medium", "high"],
    supportsEffort: true,
    value: "sonnet"
  },
  { description: "", displayName: "Sonnet 5 (1M context)", value: "sonnet[1m]" },
  {
    description: "",
    displayName: "Fable",
    supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"],
    supportsEffort: true,
    value: "claude-fable-5-1[1m]"
  },
  { description: "", displayName: "Opus", value: "opus" },
  { description: "", displayName: "Opus (1M context)", value: "opus[1m]" },
  { description: "", displayName: "Haiku", value: "haiku" }
]

export const configUpdates = (
  events: ReadonlyArray<RuntimeEvent>
): Array<Record<string, unknown>> =>
  events
    .filter((event) => event.kind === "session.updated")
    .map(payloadOf)
    .filter((payload) => Array.isArray(payload.configOptions))

export const turnPayloads = (events: ReadonlyArray<RuntimeEvent>) =>
  events
    .map(payloadOf)
    .filter(
      (payload) =>
        payload.backgroundTasks === undefined && payload.sessionUpdate !== "available_skills_update"
    )
