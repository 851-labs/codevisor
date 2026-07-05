import {
  query as sdkQuery,
  type Options as ClaudeOptions,
  type Query,
  type SDKMessage,
  type SDKUserMessage
} from "@anthropic-ai/claude-agent-sdk"
import type { DiffStat, SessionConfigOption, SessionModeState } from "@herdman/api"
import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { readFileSync } from "node:fs"
import { isAbsolute, resolve } from "node:path"
import { Effect } from "effect"
import { INLINE_IMAGE_MEDIA_TYPES, withAttachmentNotes } from "../attachments.js"
import { diffStatsFromTexts, lineCount } from "../diff-stats.js"
import {
  adapterPromise,
  normalizePromptInput,
  runtimeError,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type CreatedAgentSession,
  type HarnessDefinition,
  type LoadedAgentSession,
  type PromptAttachmentInput,
  type PromptInput,
  type ProviderEnvironment,
  type RuntimeEmit,
  type RuntimeEvent
} from "../types.js"

/// Claude Code versions older than this predate the control-protocol features
/// the Agent SDK relies on (streaming input, setModel/setPermissionMode).
const MINIMUM_CLAUDE_VERSION = "2.0.0"

/// Streaming diff-stat updates are throttled per tool call; every event is
/// persisted server-side, so unbounded input_json_delta emission would bloat
/// the events table.
const STREAM_STATS_INTERVAL_MS = 250

/// Effort levels the CLI's flag settings accept. `max` is valid (verified
/// against a live CLI) even though the SDK's `Settings` type lags its own
/// `EffortLevel` union.
const SETTABLE_EFFORT_LEVELS = new Set(["low", "medium", "high", "xhigh", "max"])

interface ClaudeModel {
  readonly value: string
  readonly name: string
  readonly supportedEffortLevels: ReadonlyArray<string>
  readonly supportsFastMode: boolean
}

type ClaudeContentBlock = Exclude<SDKUserMessage["message"]["content"], string>[number]

const isInlineForClaude = (attachment: PromptAttachmentInput): boolean =>
  (attachment.kind === "image" && INLINE_IMAGE_MEDIA_TYPES.has(attachment.mimeType)) ||
  attachment.mimeType === "application/pdf"

/// Builds the user-message content blocks: inline what the Anthropic API
/// accepts (images, PDFs), reference everything else by temp-file path.
const claudeContent = (input: PromptInput): Array<ClaudeContentBlock> => {
  const attachments = input.attachments ?? []
  const inline = attachments.filter(isInlineForClaude)
  const noted = attachments.filter((attachment) => !isInlineForClaude(attachment))
  const text = withAttachmentNotes(input.text, noted)
  const blocks: Array<ClaudeContentBlock> = []
  if (text !== "" || inline.length === 0) {
    blocks.push({ text, type: "text" })
  }
  for (const attachment of inline) {
    const data = attachment.data.toString("base64")
    blocks.push(
      attachment.mimeType === "application/pdf"
        ? { source: { data, media_type: "application/pdf", type: "base64" }, type: "document" }
        : {
            source: {
              data,
              media_type: attachment.mimeType as "image/png",
              type: "base64"
            },
            type: "image"
          }
    )
  }
  return blocks
}

// "Always Ask" (not the CLI's internal "default") mirrors the naming the
// claude-agent-acp adapter ships; a bare "Default" tells the user nothing.
const PERMISSION_MODES: SessionModeState = {
  currentModeId: "default",
  availableModes: [
    { id: "default", name: "Always Ask" },
    { id: "acceptEdits", name: "Accept Edits" },
    { id: "plan", name: "Plan" },
    { id: "bypassPermissions", name: "Bypass Permissions" }
  ]
}

export type ClaudeQueryFn = (input: {
  prompt: AsyncIterable<SDKUserMessage>
  options: ClaudeOptions
}) => Query

export interface ClaudeProviderConfig {
  /// Injectable for tests: scripted SDK message streams instead of a real CLI.
  readonly queryFn?: ClaudeQueryFn
  readonly readFile?: (path: string) => string | undefined
  readonly checkVersion?: (claudePath: string) => Promise<string>
}

/// Push-based AsyncIterable used as the SDK's streaming prompt input; keeping
/// it open keeps the Claude process alive across turns, which is what lets
/// between-turn/background output flow.
class InputQueue implements AsyncIterable<SDKUserMessage> {
  private buffer: Array<SDKUserMessage> = []
  private waiting: ((value: IteratorResult<SDKUserMessage>) => void) | undefined
  private ended = false

  push(message: SDKUserMessage): void {
    if (this.ended) return
    const waiting = this.waiting
    if (waiting !== undefined) {
      this.waiting = undefined
      waiting({ done: false, value: message })
      return
    }
    this.buffer.push(message)
  }

  end(): void {
    this.ended = true
    const waiting = this.waiting
    if (waiting !== undefined) {
      this.waiting = undefined
      waiting({ done: true, value: undefined })
    }
  }

  [Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    return {
      next: (): Promise<IteratorResult<SDKUserMessage>> => {
        const buffered = this.buffer.shift()
        if (buffered !== undefined) {
          return Promise.resolve({ done: false, value: buffered })
        }
        if (this.ended) {
          return Promise.resolve({ done: true, value: undefined })
        }
        return new Promise((resolvePromise) => {
          this.waiting = resolvePromise
        })
      }
    }
  }
}

interface Deferred<A> {
  readonly promise: Promise<A>
  readonly resolve: (value: A) => void
  readonly reject: (error: unknown) => void
}

const deferred = <A>(): Deferred<A> => {
  let resolveFn!: (value: A) => void
  let rejectFn!: (error: unknown) => void
  const promise = new Promise<A>((resolvePromise, rejectPromise) => {
    resolveFn = resolvePromise
    rejectFn = rejectPromise
  })
  promise.catch(() => undefined)
  return { promise, reject: rejectFn, resolve: resolveFn }
}

/// Accumulates the streamed partial JSON of one tool_use input so edit tools
/// can report running added/removed line counts while the model is typing.
interface ToolInputAccumulator {
  readonly toolName: string
  json: string
  lastEmit: number
  lastStats: string
  /// The file path streamed so far, once extractable — drives live titles.
  titledPath: string | undefined
  /// For Write: the pre-edit file content, read once.
  oldContent: string | null | undefined
}

/// One in-flight background task (backgrounded shell, subagent, ...) tracked
/// from the SDK's `task_*` system messages. Emitted to clients as a full
/// snapshot on every change so the UI can show what the agent is waiting on.
interface BackgroundTaskEntry {
  readonly id: string
  description: string
  status: string
  readonly taskType: string
  readonly toolUseId?: string
}

interface ClaudeSession {
  /// The id the runtime and server know this session by (== SDK session id
  /// for new sessions; the requested id for resumed ones).
  readonly key: string
  readonly sdkSessionId: string
  readonly cwd: string
  readonly q: Query
  readonly input: InputQueue
  readonly emit: RuntimeEmit
  readonly abort: AbortController
  turnActive: boolean
  turnId: string
  initiatedBy: "user" | "agent"
  pendingPrompt: Deferred<{ stopReason: string }> | undefined
  interruptRequested: boolean
  currentMessageId: string | undefined
  currentModel: string
  currentEffort: string
  currentSpeed: "standard" | "fast"
  models: ReadonlyArray<ClaudeModel>
  readonly accumulators: Map<string, ToolInputAccumulator>
  readonly openToolCalls: Set<string>
  /// Current message id per streaming subagent, keyed by the subagent's
  /// parent tool_use id — keeps subagent text spans stable across replay
  /// without touching the main agent's `currentMessageId`.
  readonly subagentMessageIds: Map<string, string>
  /// Cross-turn: background tasks legitimately outlive the turn that spawned
  /// them, so this is never cleared at turn end.
  readonly backgroundTasks: Map<string, BackgroundTaskEntry>
}

export const makeClaudeProvider = (
  environment: ProviderEnvironment,
  config: ClaudeProviderConfig = {}
): AgentProvider => {
  const queryFn = config.queryFn ?? ((input) => sdkQuery(input))
  const readFile =
    config.readFile ??
    ((path: string): string | undefined => {
      try {
        return readFileSync(path, "utf8")
      } catch {
        return undefined
      }
    })
  const checkVersion = config.checkVersion ?? runClaudeVersion
  const versionCache = new Map<string, string>()

  const locateClaude = (definition: HarnessDefinition): string => {
    const binary = definition.detectBinaries[0] ?? "claude"
    const located = environment.locateExecutable(binary, environment.env)
    if (located === undefined) {
      throw new Error(`${binary} not found on PATH`)
    }
    return located
  }

  const guardVersion = async (claudePath: string): Promise<void> => {
    let version = versionCache.get(claudePath)
    if (version === undefined) {
      version = await checkVersion(claudePath)
      versionCache.set(claudePath, version)
    }
    if (compareVersions(version, MINIMUM_CLAUDE_VERSION) < 0) {
      throw new Error(
        `Claude Code ${version} is older than the required ${MINIMUM_CLAUDE_VERSION}. Update with: claude update`
      )
    }
  }

  const startSession = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    resume: string | undefined
  ): Promise<ClaudeSession> => {
    const claudePath = locateClaude(definition)
    await guardVersion(claudePath)

    // In streaming-input mode the SDK emits `system:init` only once the first
    // user message is sent, so session creation must not block on it. The
    // session id is assigned up front via the CLI's --session-id flag; init
    // later confirms it and fills in the model.
    const sessionKey = resume ?? randomUUID()
    const input = new InputQueue()
    const abort = new AbortController()
    // Filled in below; the hook and pump close over it.
    let session: ClaudeSession | undefined
    const options: ClaudeOptions = {
      abortController: abort,
      cwd,
      includePartialMessages: true,
      pathToClaudeCodeExecutable: claudePath,
      // Matches the previous app behavior of auto-approving agent requests;
      // this callback is the seam for a real permission UI.
      canUseTool: async (_toolName, toolInput) => ({
        behavior: "allow",
        updatedInput: toolInput
      }),
      hooks: {
        PostToolUse: [
          {
            hooks: [
              async (hookInput) => {
                if (hookInput.hook_event_name === "PostToolUse" && session !== undefined) {
                  emitAuthoritativeDiff(session, hookInput, readFile)
                }
                return {}
              }
            ]
          }
        ]
      },
      ...(resume === undefined ? { extraArgs: { "session-id": sessionKey } } : { resume })
    }
    const q = queryFn({ prompt: input, options })

    const created: ClaudeSession = {
      abort,
      accumulators: new Map(),
      backgroundTasks: new Map(),
      currentEffort: "default",
      currentMessageId: undefined,
      currentModel: "",
      currentSpeed: "standard",
      cwd,
      emit,
      initiatedBy: "user",
      input,
      interruptRequested: false,
      key: sessionKey,
      models: [],
      openToolCalls: new Set(),
      pendingPrompt: undefined,
      q,
      sdkSessionId: sessionKey,
      subagentMessageIds: new Map(),
      turnActive: false,
      turnId: randomUUID()
    }
    session = created
    // A fresh session has no background work by definition; this snapshot
    // clears any stale "running" state a client may replay from a previous
    // server process's event log.
    emitBackgroundTasks(created)

    const pump = async (): Promise<void> => {
      try {
        for await (const message of q) {
          if (message.type === "system" && message.subtype === "init") {
            created.currentModel = message.model
            if (message.fast_mode_state !== undefined) {
              created.currentSpeed = message.fast_mode_state === "on" ? "fast" : "standard"
            }
            continue
          }
          handleMessage(created, message, readFile)
        }
      } catch (cause) {
        const failure = cause instanceof Error ? cause.message : String(cause)
        created.pendingPrompt?.reject(runtimeError("prompt", cause))
        created.pendingPrompt = undefined
        void created.emit({
          kind: "session.error",
          payload: { message: failure },
          subjectId: created.key
        })
      }
    }
    pump().catch(() => undefined)

    // Best-effort model list: the control channel usually answers before the
    // first turn, but session creation must not hang on it.
    try {
      const models = await Promise.race([
        q.supportedModels(),
        new Promise<undefined>((resolvePromise) =>
          setTimeout(() => resolvePromise(undefined), 3000)
        )
      ])
      if (models !== undefined) {
        // The CLI's "default" pseudo-model is an alias, not a model — the
        // picker shows real models only.
        created.models = models
          .filter((model) => model.value !== "default")
          .map((model) => ({
            name: model.displayName,
            supportedEffortLevels: (model.supportsEffort === true
              ? (model.supportedEffortLevels ?? [])
              : []
            ).filter((level) => SETTABLE_EFFORT_LEVELS.has(level)),
            supportsFastMode: model.supportsFastMode === true,
            value: model.value
          }))
        if (
          (created.currentModel.length === 0 || created.currentModel === "default") &&
          created.models[0] !== undefined
        ) {
          created.currentModel = created.models[0].value
        }
      }
    } catch {
      created.models = []
    }
    return created
  }

  const metadataFor = (
    session: ClaudeSession
  ): {
    modes: SessionModeState
    configOptions: ReadonlyArray<SessionConfigOption>
  } => {
    const options: Array<SessionConfigOption> = []
    if (session.models.length > 0) {
      options.push({
        category: "model",
        currentValue: session.currentModel,
        id: "model",
        name: "Model",
        options: session.models.map((model) => ({ name: model.name, value: model.value }))
      })
    }
    const effortLevels = effortLevelsFor(session)
    if (effortLevels.length > 0) {
      options.push({
        category: "thought_level",
        // No synthetic "Default" entry: until the user picks a level the CLI
        // runs at its own default ("high" on effort-capable models), so
        // surface that as the selection.
        currentValue: effortLevels.includes(session.currentEffort)
          ? session.currentEffort
          : defaultEffortFor(effortLevels),
        id: "effort",
        name: "Effort",
        options: effortLevels.map((level) => ({
          name: level === "xhigh" ? "X-High" : (level[0]?.toUpperCase() ?? "") + level.slice(1),
          value: level
        }))
      })
    }
    if (supportsFastMode(session)) {
      options.push({
        category: "speed",
        currentValue: session.currentSpeed,
        id: "speed",
        name: "Speed",
        options: [
          { name: "Standard", value: "standard" },
          { description: "Prioritized, faster responses", name: "Fast", value: "fast" }
        ]
      })
    }
    return { configOptions: options, modes: PERMISSION_MODES }
  }

  const effortLevelsFor = (session: ClaudeSession): ReadonlyArray<string> =>
    session.models.find((model) => model.value === session.currentModel)?.supportedEffortLevels ??
    []

  const supportsFastMode = (session: ClaudeSession): boolean =>
    session.models.find((model) => model.value === session.currentModel)?.supportsFastMode === true

  /// The CLI's default effort for effort-capable models is "high".
  const defaultEffortFor = (levels: ReadonlyArray<string>): string =>
    levels.includes("high") ? "high" : (levels[0] ?? "high")

  const handleFor = (session: ClaudeSession): AgentSessionHandle => ({
    cancel: adapterPromise("cancel", async () => {
      session.interruptRequested = true
      try {
        await session.q.interrupt()
      } catch {
        // The turn may have ended between the request and the interrupt.
      }
    }),
    close: adapterPromise("close", async () => {
      session.input.end()
      session.abort.abort()
    }),
    prompt: (input) =>
      adapterPromise("prompt", async () => {
        const pending = deferred<{ stopReason: string }>()
        session.pendingPrompt = pending
        await ensureTurnStarted(session, "user")
        session.input.push({
          message: { content: claudeContent(normalizePromptInput(input)), role: "user" },
          parent_tool_use_id: null,
          session_id: session.sdkSessionId,
          type: "user"
        })
        return pending.promise
      }),
    setConfigOption: (configId, value) =>
      adapterPromise("setConfigOption", async () => {
        if (configId === "model") {
          await session.q.setModel(value)
          session.currentModel = value
          // Effort validity depends on the model; reset rather than carry an
          // unsupported level over.
          if (!effortLevelsFor(session).includes(session.currentEffort)) {
            session.currentEffort = "default"
          }
          // Same for speed: switch fast mode off rather than carry it to a
          // model that doesn't support it.
          if (session.currentSpeed === "fast" && !supportsFastMode(session)) {
            await session.q.applyFlagSettings({ fastMode: false })
            session.currentSpeed = "standard"
          }
        } else if (configId === "effort") {
          // Cast: the CLI accepts "max" but the SDK Settings type doesn't
          // list it yet.
          await session.q.applyFlagSettings({
            effortLevel: value === "default" ? null : value
          } as Parameters<Query["applyFlagSettings"]>[0])
          session.currentEffort = value
        } else if (configId === "speed") {
          await session.q.applyFlagSettings({ fastMode: value === "fast" })
          session.currentSpeed = value === "fast" ? "fast" : "standard"
        } else {
          throw new Error(`Unknown config option: ${configId}`)
        }
        await session.emit({
          kind: "session.updated",
          payload: {
            configId,
            configOptions: metadataFor(session).configOptions,
            value
          },
          subjectId: session.key
        })
      }),
    setMode: (modeId) =>
      adapterPromise("setMode", async () => {
        await session.q.setPermissionMode(modeId as never)
        await session.emit({
          kind: "session.updated",
          payload: { modeId },
          subjectId: session.key
        })
      })
  })

  return {
    createSession: (definition, cwd, emit): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
      adapterPromise("createSession", async () => {
        const session = await startSession(definition, cwd, emit, undefined)
        return {
          handle: handleFor(session),
          metadata: { sessionId: session.key, ...metadataFor(session) }
        }
      }),
    id: "claude",
    loadSession: (
      definition,
      agentSessionId,
      cwd,
      emit
    ): Effect.Effect<LoadedAgentSession, AgentRuntimeError> =>
      adapterPromise("loadSession", async () => {
        const session = await startSession(definition, cwd, emit, agentSessionId)
        return { handle: handleFor(session), sessionId: session.key }
      }),
    readiness: (definition) => {
      const installed = definition.detectBinaries.some((binary) =>
        environment.executableExists(binary, environment.env)
      )
      return installed
        ? { state: "ready" }
        : { detail: "CLI not found on PATH", state: "unavailable" }
    }
  }
}

// MARK: message pump

const handleMessage = (
  session: ClaudeSession,
  message: SDKMessage,
  readFile: (path: string) => string | undefined
): void => {
  switch (message.type) {
    case "stream_event":
      handleStreamEvent(session, message, readFile)
      break
    case "assistant": {
      const parentId = message.parent_tool_use_id ?? undefined
      if (parentId === undefined) {
        void ensureTurnStarted(session, session.pendingPrompt === undefined ? "agent" : "user")
      }
      const content = message.message.content
      if (!Array.isArray(content)) break
      const inner = message.message as unknown as Record<string, unknown>
      const messageId = typeof inner.id === "string" ? inner.id : undefined
      // The CLI does not forward subagent stream events, so a subagent's prose
      // exists only here, in its consolidated assistant messages. Emit it
      // tagged with the parent tool call — unless this message DID stream
      // (older CLIs), in which case the chunks are already out and re-emitting
      // would double the text.
      const alreadyStreamed =
        parentId !== undefined &&
        messageId !== undefined &&
        session.subagentMessageIds.get(parentId) === messageId
      for (const block of content) {
        if (!isRecord(block)) continue
        if (block.type === "text" && parentId !== undefined && !alreadyStreamed) {
          const text = String(block.text ?? "")
          if (text.length === 0) continue
          void session.emit({
            kind: "session.output",
            payload: {
              content: { text, type: "text" },
              parentToolCallId: parentId,
              sessionUpdate: "agent_message_chunk",
              ...(messageId === undefined ? {} : { messageId })
            },
            subjectId: session.key
          })
        } else if (block.type === "tool_use") {
          const toolUseId = String(block.id)
          const toolName = String(block.name)
          const stats = authoritativeStatsFromInput(session, toolName, block.input, readFile)
          void session.emit({
            kind: "session.output",
            payload: {
              // The streamed tool_call may never have existed for subagent
              // tools (no subagent stream events), so this update must carry
              // enough to create the call outright — including its kind.
              kind: toolKind(toolName),
              rawInput: block.input,
              sessionUpdate: "tool_call_update",
              status: "in_progress",
              title: toolTitle(toolName, block.input),
              toolCallId: toolUseId,
              ...(stats === undefined ? {} : { diffStats: stats }),
              ...(parentId === undefined ? {} : { parentToolCallId: parentId })
            },
            subjectId: session.key
          })
        }
      }
      break
    }
    case "user": {
      const content = message.message.content
      if (!Array.isArray(content)) break
      for (const block of content) {
        if (isRecord(block) && block.type === "tool_result") {
          const toolUseId = String(block.tool_use_id)
          session.openToolCalls.delete(toolUseId)
          const accumulator = session.accumulators.get(toolUseId)
          const doneTitle =
            accumulator !== undefined && accumulator.titledPath !== undefined
              ? finishedToolTitle(accumulator.toolName, accumulator.titledPath)
              : undefined
          void session.emit({
            kind: "session.output",
            payload: {
              rawOutput: block.content,
              sessionUpdate: "tool_call_update",
              status: block.is_error === true ? "failed" : "completed",
              toolCallId: toolUseId,
              ...(doneTitle === undefined ? {} : { title: doneTitle })
            },
            subjectId: session.key
          })
        }
      }
      break
    }
    case "result":
      handleResult(session, message)
      break
    case "system":
      handleSystemMessage(session, message)
      break
    default:
      break
  }
}

/// Tracks the SDK's background-task lifecycle (`task_*` system messages) so
/// clients can tell "idle" apart from "turn ended, waiting on background
/// work". Every change emits a full replace-on-update snapshot.
const handleSystemMessage = (
  session: ClaudeSession,
  message: Extract<SDKMessage, { type: "system" }>
): void => {
  switch (message.subtype) {
    case "task_started": {
      // Ambient/housekeeping tasks should not make the chat look busy.
      if (message.skip_transcript === true) break
      session.backgroundTasks.set(message.task_id, {
        description: message.description,
        id: message.task_id,
        status: "running",
        taskType: message.subagent_type !== undefined ? "subagent" : (message.task_type ?? "task"),
        ...(message.tool_use_id === undefined ? {} : { toolUseId: message.tool_use_id })
      })
      emitBackgroundTasks(session)
      // Retitle the spawning tool call with the task's description — the most
      // reliable source, immune to the Task→Agent tool rename.
      if (message.subagent_type !== undefined && message.tool_use_id !== undefined) {
        void session.emit({
          kind: "session.output",
          payload: {
            kind: "agent",
            sessionUpdate: "tool_call_update",
            title: `Agent: ${message.description}`,
            toolCallId: message.tool_use_id
          },
          subjectId: session.key
        })
      }
      break
    }
    case "task_progress": {
      const entry = session.backgroundTasks.get(message.task_id)
      if (entry === undefined || message.summary === undefined) break
      if (entry.description === message.summary) break
      entry.description = message.summary
      emitBackgroundTasks(session)
      break
    }
    case "task_updated": {
      const entry = session.backgroundTasks.get(message.task_id)
      if (entry === undefined) break
      const status = message.patch.status
      if (status === "completed" || status === "failed" || status === "killed") {
        session.backgroundTasks.delete(message.task_id)
      } else {
        if (status !== undefined) entry.status = status
        if (message.patch.description !== undefined) entry.description = message.patch.description
      }
      emitBackgroundTasks(session)
      break
    }
    case "task_notification": {
      if (session.backgroundTasks.delete(message.task_id)) {
        emitBackgroundTasks(session)
      }
      break
    }
    default:
      break
  }
}

const emitBackgroundTasks = (session: ClaudeSession): void => {
  void session.emit({
    kind: "session.updated",
    payload: { backgroundTasks: [...session.backgroundTasks.values()] },
    subjectId: session.key
  })
}

const handleStreamEvent = (
  session: ClaudeSession,
  message: Extract<SDKMessage, { type: "stream_event" }>,
  readFile: (path: string) => string | undefined
): void => {
  const event = message.event as unknown as Record<string, unknown>
  const parentId = message.parent_tool_use_id ?? undefined
  switch (event.type) {
    case "message_start": {
      const inner = event.message
      const innerId = isRecord(inner) ? String(inner.id ?? "") : undefined
      if (parentId === undefined) {
        session.currentMessageId = innerId
        void ensureTurnStarted(session, session.pendingPrompt === undefined ? "agent" : "user")
      } else if (innerId !== undefined && innerId !== "") {
        session.subagentMessageIds.set(parentId, innerId)
      }
      break
    }
    case "content_block_start": {
      const block = event.content_block
      if (isRecord(block) && block.type === "tool_use") {
        const toolUseId = String(block.id)
        const toolName = String(block.name)
        session.accumulators.set(toolUseId, {
          json: "",
          lastEmit: 0,
          lastStats: "",
          oldContent: undefined,
          titledPath: undefined,
          toolName
        })
        session.openToolCalls.add(toolUseId)
        void ensureTurnStarted(session, session.pendingPrompt === undefined ? "agent" : "user")
        // The model is already generating this call's input — that's work in
        // progress, and for fast tools it's most of the visible lifetime.
        void session.emit({
          kind: "session.output",
          payload: {
            kind: toolKind(toolName),
            sessionUpdate: "tool_call",
            status: "in_progress",
            title: toolName,
            toolCallId: toolUseId,
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
      }
      break
    }
    case "content_block_delta": {
      const delta = event.delta
      if (!isRecord(delta)) break
      if (delta.type === "text_delta") {
        // Subagent prose flows tagged with its parent tool call so clients can
        // nest it under the Task row instead of mixing it into the main thread.
        const messageId =
          parentId === undefined
            ? session.currentMessageId
            : session.subagentMessageIds.get(parentId)
        void session.emit({
          kind: "session.output",
          payload: {
            content: { text: String(delta.text ?? ""), type: "text" },
            sessionUpdate: "agent_message_chunk",
            ...(messageId === undefined ? {} : { messageId }),
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
      } else if (delta.type === "thinking_delta") {
        void session.emit({
          kind: "session.output",
          payload: {
            content: { text: String(delta.thinking ?? ""), type: "text" },
            sessionUpdate: "agent_thought_chunk",
            ...(parentId === undefined ? {} : { parentToolCallId: parentId })
          },
          subjectId: session.key
        })
      } else if (delta.type === "input_json_delta") {
        const toolUseId = String(event.index !== undefined ? findAccumulatorId(session, event) : "")
        const accumulator = session.accumulators.get(toolUseId)
        if (accumulator !== undefined) {
          accumulator.json += String(delta.partial_json ?? "")
          maybeEmitStreamStats(session, toolUseId, accumulator, readFile, false)
        }
      }
      break
    }
    case "content_block_stop": {
      const toolUseId = findAccumulatorId(session, event)
      const accumulator = session.accumulators.get(toolUseId)
      if (accumulator !== undefined) {
        maybeEmitStreamStats(session, toolUseId, accumulator, readFile, true)
      }
      break
    }
    default:
      break
  }
}

/// The Anthropic stream identifies blocks by index, not id. Content blocks
/// stream strictly sequentially per message, so the accumulator opened last
/// is the one receiving deltas.
const findAccumulatorId = (session: ClaudeSession, _event: Record<string, unknown>): string => {
  let lastKey = ""
  for (const key of session.accumulators.keys()) {
    lastKey = key
  }
  return lastKey
}

const handleResult = (session: ClaudeSession, message: SDKMessage & { type: "result" }): void => {
  // Anything still open never got a tool_result (interrupt/failure).
  for (const toolUseId of [...session.openToolCalls]) {
    session.openToolCalls.delete(toolUseId)
    void session.emit({
      kind: "session.output",
      payload: {
        sessionUpdate: "tool_call_update",
        status: session.interruptRequested ? "cancelled" : "failed",
        toolCallId: toolUseId
      },
      subjectId: session.key
    })
  }
  session.accumulators.clear()
  session.subagentMessageIds.clear()

  const stopReason = session.interruptRequested
    ? "cancelled"
    : message.subtype === "error_max_turns"
      ? "max_turn_requests"
      : "end_turn"
  if (message.subtype !== "success" && !session.interruptRequested) {
    const errors = "errors" in message && Array.isArray(message.errors) ? message.errors : []
    void session.emit({
      kind: "session.error",
      payload: {
        message: errors.length > 0 ? errors.join("\n") : `Claude Code failed: ${message.subtype}`
      },
      subjectId: session.key
    })
  }
  const ended: RuntimeEvent = {
    kind: "session.updated",
    payload: {
      initiatedBy: session.initiatedBy,
      stopReason,
      turnId: session.turnId,
      turnState: "ended"
    },
    subjectId: session.key
  }
  const pending = session.pendingPrompt
  session.pendingPrompt = undefined
  session.turnActive = false
  session.interruptRequested = false
  void session.emit(ended).then(() => {
    pending?.resolve({ stopReason })
  })
}

const ensureTurnStarted = (
  session: ClaudeSession,
  initiatedBy: "user" | "agent"
): Promise<void> => {
  if (session.turnActive) return Promise.resolve()
  session.turnActive = true
  session.turnId = randomUUID()
  session.initiatedBy = initiatedBy
  return session.emit({
    kind: "session.updated",
    payload: { initiatedBy, turnId: session.turnId, turnState: "started" },
    subjectId: session.key
  })
}

// MARK: diff stats

const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"])

const maybeEmitStreamStats = (
  session: ClaudeSession,
  toolUseId: string,
  accumulator: ToolInputAccumulator,
  readFile: (path: string) => string | undefined,
  force: boolean
): void => {
  if (!EDIT_TOOLS.has(accumulator.toolName)) return
  const now = Date.now()
  if (!force && now - accumulator.lastEmit < STREAM_STATS_INTERVAL_MS) return
  const stats = streamingStats(session, accumulator, readFile)
  if (stats === undefined) return
  const fingerprint = JSON.stringify(stats)
  if (fingerprint === accumulator.lastStats) return
  accumulator.lastEmit = now
  accumulator.lastStats = fingerprint
  const path = stats[0]?.path
  const title =
    path !== undefined && accumulator.titledPath !== path
      ? activeToolTitle(accumulator.toolName, path)
      : undefined
  if (path !== undefined) {
    accumulator.titledPath = path
  }
  void session.emit({
    kind: "session.output",
    payload: {
      diffStats: stats,
      sessionUpdate: "tool_call_update",
      status: "in_progress",
      toolCallId: toolUseId,
      ...(title === undefined ? {} : { title })
    },
    subjectId: session.key
  })
}

/// Running estimate computed from the partially streamed tool input. Counts
/// only ever grow as the strings stream in; the consolidated input and the
/// PostToolUse hook later replace them with authoritative numbers.
const streamingStats = (
  session: ClaudeSession,
  accumulator: ToolInputAccumulator,
  readFile: (path: string) => string | undefined
): Array<DiffStat> | undefined => {
  const path = extractStringField(accumulator.json, "file_path")
  if (path === undefined || path.length === 0) return undefined
  switch (accumulator.toolName) {
    case "Edit": {
      const oldString = extractStringField(accumulator.json, "old_string") ?? ""
      const newString = extractStringField(accumulator.json, "new_string") ?? ""
      return [{ added: lineCount(newString), path, removed: lineCount(oldString) }]
    }
    case "Write": {
      if (accumulator.oldContent === undefined) {
        accumulator.oldContent = readFile(absolutePath(session.cwd, path)) ?? null
      }
      const content = extractStringField(accumulator.json, "content") ?? ""
      return [
        {
          added: lineCount(content),
          path,
          removed: accumulator.oldContent === null ? 0 : lineCount(accumulator.oldContent)
        }
      ]
    }
    case "MultiEdit": {
      const oldStrings = extractAllStringFields(accumulator.json, "old_string")
      const newStrings = extractAllStringFields(accumulator.json, "new_string")
      return [
        {
          added: newStrings.reduce((total, text) => total + lineCount(text), 0),
          path,
          removed: oldStrings.reduce((total, text) => total + lineCount(text), 0)
        }
      ]
    }
    default:
      return undefined
  }
}

/// Authoritative stats from the consolidated (fully parsed) tool input.
const authoritativeStatsFromInput = (
  session: ClaudeSession,
  toolName: string,
  input: unknown,
  readFile: (path: string) => string | undefined
): Array<DiffStat> | undefined => {
  if (!EDIT_TOOLS.has(toolName) || !isRecord(input)) return undefined
  const path = typeof input.file_path === "string" ? input.file_path : undefined
  if (path === undefined) return undefined
  switch (toolName) {
    case "Edit": {
      const oldString = typeof input.old_string === "string" ? input.old_string : ""
      const newString = typeof input.new_string === "string" ? input.new_string : ""
      return [diffStatsFromTexts(path, oldString, newString)]
    }
    case "Write": {
      const content = typeof input.content === "string" ? input.content : ""
      const oldContent = readFile(absolutePath(session.cwd, path))
      return [diffStatsFromTexts(path, oldContent, content)]
    }
    case "MultiEdit": {
      const edits = Array.isArray(input.edits) ? input.edits : []
      let added = 0
      let removed = 0
      for (const edit of edits) {
        if (!isRecord(edit)) continue
        const stats = diffStatsFromTexts(
          path,
          typeof edit.old_string === "string" ? edit.old_string : "",
          typeof edit.new_string === "string" ? edit.new_string : ""
        )
        added += stats.added
        removed += stats.removed
      }
      return [{ added, path, removed }]
    }
    default:
      return undefined
  }
}

/// PostToolUse delivers the on-disk truth (structuredPatch reflects
/// replace_all and the file's actual state); emit the final stats plus a
/// renderable diff content block.
const emitAuthoritativeDiff = (
  session: ClaudeSession,
  hookInput: {
    tool_name: string
    tool_input: unknown
    tool_response: unknown
    tool_use_id: string
  },
  readFile: (path: string) => string | undefined
): void => {
  if (!EDIT_TOOLS.has(hookInput.tool_name)) return
  const input = isRecord(hookInput.tool_input) ? hookInput.tool_input : {}
  const path = typeof input.file_path === "string" ? input.file_path : undefined
  if (path === undefined) return

  const response = isRecord(hookInput.tool_response) ? hookInput.tool_response : {}
  let stats: DiffStat | undefined
  if (Array.isArray(response.structuredPatch)) {
    let added = 0
    let removed = 0
    for (const hunk of response.structuredPatch) {
      if (!isRecord(hunk) || !Array.isArray(hunk.lines)) continue
      for (const line of hunk.lines) {
        if (typeof line !== "string") continue
        if (line.startsWith("+")) added += 1
        else if (line.startsWith("-")) removed += 1
      }
    }
    stats = { added, path, removed }
  }

  const diffBlock = diffContentBlock(session, hookInput.tool_name, input, response, path, readFile)
  if (stats === undefined && diffBlock === undefined) return
  void session.emit({
    kind: "session.output",
    payload: {
      sessionUpdate: "tool_call_update",
      toolCallId: hookInput.tool_use_id,
      ...(stats === undefined ? {} : { diffStats: [stats] }),
      ...(diffBlock === undefined ? {} : { content: [diffBlock] }),
      ...(stats === undefined && diffBlock !== undefined
        ? { diffStats: [diffStatsFromTexts(path, diffBlock.oldText, diffBlock.newText)] }
        : {})
    },
    subjectId: session.key
  })
}

const diffContentBlock = (
  session: ClaudeSession,
  toolName: string,
  input: Record<string, unknown>,
  response: Record<string, unknown>,
  path: string,
  readFile: (path: string) => string | undefined
): { type: "diff"; path: string; oldText: string | null; newText: string } | undefined => {
  switch (toolName) {
    case "Edit": {
      const oldString = typeof input.old_string === "string" ? input.old_string : null
      const newString = typeof input.new_string === "string" ? input.new_string : ""
      return { newText: newString, oldText: oldString, path, type: "diff" }
    }
    case "Write": {
      const content = typeof input.content === "string" ? input.content : ""
      const original =
        typeof response.originalFile === "string"
          ? response.originalFile
          : readFile(absolutePath(session.cwd, path)) === content
            ? null
            : null
      return { newText: content, oldText: original, path, type: "diff" }
    }
    default:
      return undefined
  }
}

// MARK: helpers

const absolutePath = (cwd: string, path: string): string =>
  isAbsolute(path) ? path : resolve(cwd, path)

const toolKind = (toolName: string): string => {
  switch (toolName) {
    case "Read":
      return "read"
    case "Edit":
    case "Write":
    case "MultiEdit":
    case "NotebookEdit":
      return "edit"
    case "Bash":
    case "BashOutput":
    case "KillShell":
      return "execute"
    case "Grep":
    case "Glob":
      return "search"
    case "WebFetch":
    case "WebSearch":
      return "fetch"
    case "TodoWrite":
      return "think"
    // The subagent-spawn tool: "Task" historically, "Agent" in newer CLIs.
    case "Task":
    case "Agent":
      return "agent"
    default:
      return "other"
  }
}

const fileNameOf = (path: string): string => path.split("/").at(-1) ?? path

/// Present-tense title while a file tool is running.
const activeToolTitle = (toolName: string, path: string): string | undefined => {
  const file = fileNameOf(path)
  switch (toolName) {
    case "Edit":
    case "MultiEdit":
      return `Editing ${file}`
    case "Write":
      return `Writing ${file}`
    default:
      return undefined
  }
}

/// Past-tense title once the tool has finished.
const finishedToolTitle = (toolName: string, path: string): string | undefined => {
  const file = fileNameOf(path)
  switch (toolName) {
    case "Edit":
    case "MultiEdit":
      return `Edited ${file}`
    case "Write":
      return `Wrote ${file}`
    default:
      return undefined
  }
}

const toolTitle = (toolName: string, input: unknown): string => {
  if (isRecord(input)) {
    if (typeof input.file_path === "string") {
      const file = input.file_path.split("/").at(-1) ?? input.file_path
      switch (toolName) {
        case "Read":
          return `Read ${file}`
        case "Edit":
        case "MultiEdit":
          return `Edited ${file}`
        case "Write":
          return `Wrote ${file}`
        default:
          break
      }
    }
    if (toolName === "Bash" && typeof input.command === "string") {
      return `Ran ${input.command.split("\n")[0]?.slice(0, 80) ?? ""}`
    }
    if (typeof input.pattern === "string") {
      return `Searched for ${input.pattern}`
    }
    if ((toolName === "Task" || toolName === "Agent") && typeof input.description === "string") {
      return `Agent: ${input.description}`
    }
  }
  return toolName
}

/// Extracts a JSON string field's (possibly still-streaming) value from a
/// partial JSON buffer without a full parser: finds `"field":"` and decodes
/// escapes until the closing quote or the end of the buffer.
export const extractStringField = (json: string, field: string): string | undefined => {
  const key = `"${field}"`
  let index = json.indexOf(key)
  if (index === -1) return undefined
  index += key.length
  while (index < json.length && (json[index] === " " || json[index] === ":")) index += 1
  if (json[index] !== '"') return undefined
  index += 1
  return decodeJsonString(json, index).value
}

/// Extracts every occurrence of a string field (for MultiEdit's edits array).
export const extractAllStringFields = (json: string, field: string): Array<string> => {
  const key = `"${field}"`
  const values: Array<string> = []
  let cursor = 0
  while (true) {
    let index = json.indexOf(key, cursor)
    if (index === -1) return values
    index += key.length
    while (index < json.length && (json[index] === " " || json[index] === ":")) index += 1
    if (json[index] !== '"') {
      cursor = index
      continue
    }
    index += 1
    const decoded = decodeJsonString(json, index)
    values.push(decoded.value)
    cursor = decoded.end
  }
}

const decodeJsonString = (json: string, start: number): { value: string; end: number } => {
  let out = ""
  let index = start
  while (index < json.length) {
    const ch = json[index]
    if (ch === "\\") {
      const next = json[index + 1]
      if (next === undefined) break
      switch (next) {
        case "n":
          out += "\n"
          break
        case "t":
          out += "\t"
          break
        case "r":
          out += "\r"
          break
        case '"':
          out += '"'
          break
        case "\\":
          out += "\\"
          break
        case "/":
          out += "/"
          break
        case "u": {
          const hex = json.slice(index + 2, index + 6)
          if (hex.length === 4 && /^[0-9a-fA-F]{4}$/.test(hex)) {
            out += String.fromCharCode(Number.parseInt(hex, 16))
            index += 4
          }
          break
        }
        default:
          out += next
      }
      index += 2
      continue
    }
    if (ch === '"') {
      return { end: index + 1, value: out }
    }
    out += ch
    index += 1
  }
  return { end: index, value: out }
}

const compareVersions = (left: string, right: string): number => {
  const leftParts = left.split(".").map((part) => Number.parseInt(part, 10) || 0)
  const rightParts = right.split(".").map((part) => Number.parseInt(part, 10) || 0)
  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0)
    if (difference !== 0) return difference < 0 ? -1 : 1
  }
  return 0
}

/* v8 ignore start -- exercised against a live claude binary, not in unit tests. */
const runClaudeVersion = (claudePath: string): Promise<string> =>
  new Promise((resolvePromise, rejectPromise) => {
    execFile(claudePath, ["--version"], { timeout: 5000 }, (error, stdout) => {
      if (error !== null) {
        rejectPromise(new Error(`claude --version failed: ${error.message}`))
        return
      }
      const match = /(\d+\.\d+\.\d+)/.exec(stdout)
      if (match?.[1] === undefined) {
        rejectPromise(new Error(`Could not parse claude version from: ${stdout.trim()}`))
        return
      }
      resolvePromise(match[1])
    })
  })
/* v8 ignore stop */

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
