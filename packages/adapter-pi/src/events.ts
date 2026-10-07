import {
  diffStatsFromTexts,
  diffStatsFromUnified,
  textsFromUnifiedDiff
} from "@codevisor/agent-runtime"
import type { EventKind } from "@codevisor/api"

/// Maps Pi's RPC session events onto Codevisor's transcript events.

export interface MappedEvent {
  readonly kind: EventKind
  readonly payload: Record<string, unknown>
}

export interface PiAssistantOutcome {
  readonly stopReason: string
  readonly errorMessage?: string
}

const record = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {}

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

const finite = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) ? value : 0

/// Pi's built-in tools, as Codevisor's tool kinds.
export const piToolKind = (name: string): string => {
  switch (name) {
    case "read":
      return "read"
    case "bash":
      return "execute"
    case "edit":
    case "write":
      return "edit"
    case "grep":
    case "find":
    case "ls":
      return "search"
    default:
      return "other"
  }
}

/// What the call acts on: the file, command or pattern.
export const piToolTitle = (name: string, args: Record<string, unknown>): string =>
  text(args.command) ?? text(args.path) ?? text(args.pattern) ?? name

const locations = (args: Record<string, unknown>) => {
  const path = text(args.path)
  return path === undefined ? {} : { locations: [{ path }] }
}

/// The text a tool result carries.
const resultText = (result: Record<string, unknown>): string | undefined => {
  const content = Array.isArray(result.content) ? result.content : []
  const joined = content
    .flatMap((block) => {
      const entry = record(block)
      return entry.type === "text" && typeof entry.text === "string" ? [entry.text] : []
    })
    .join("")
  return joined.length === 0 ? undefined : joined
}

const textContent = (value: string | undefined) =>
  value === undefined ? [] : [{ type: "content", content: { type: "text", text: value } }]

/// An edit's or write's diff, for the transcript's diff view.
const fileChange = (
  name: string,
  args: Record<string, unknown>,
  result: Record<string, unknown>
) => {
  const path = text(args.path)
  if (path === undefined) return {}
  if (name === "write" && typeof args.content === "string") {
    const newText = args.content
    return {
      content: [{ type: "diff", path, oldText: null, newText }],
      diffStats: [diffStatsFromTexts(path, undefined, newText)]
    }
  }
  const patch = text(record(result.details).patch)
  const texts = patch === undefined ? undefined : textsFromUnifiedDiff(patch)
  if (patch === undefined || texts === undefined) return {}
  return {
    content: [{ type: "diff", path, ...texts }],
    diffStats: [diffStatsFromUnified(path, patch)]
  }
}

const output = (payload: Record<string, unknown>): MappedEvent => ({
  kind: "session.output",
  payload
})

const updated = (payload: Record<string, unknown>): MappedEvent => ({
  kind: "session.updated",
  payload
})

export interface PiEventMapper {
  readonly map: (event: Record<string, unknown>) => ReadonlyArray<MappedEvent>
  /// How the newest assistant response ended.
  readonly outcome: () => PiAssistantOutcome | undefined
  /// Forget the previous run's outcome.
  readonly startRun: () => void
}

export const makePiEventMapper = (contextWindow: () => number | undefined): PiEventMapper => {
  /// Identifies the streaming assistant message; text blocks append their index.
  let message = ""
  let messages = 0
  let outcome: PiAssistantOutcome | undefined
  const totals = { input: 0, cacheRead: 0, output: 0, reasoning: 0, total: 0 }
  const tools = new Map<string, { name: string; args: Record<string, unknown> }>()
  let compactions = 0

  const tool = (id: string, name: string, args: Record<string, unknown>) => {
    tools.set(id, { name, args })
    return {
      toolCallId: id,
      kind: piToolKind(name),
      title: piToolTitle(name, args),
      ...locations(args)
    }
  }

  const streaming = (update: Record<string, unknown>): ReadonlyArray<MappedEvent> => {
    const index = finite(update.contentIndex)
    switch (update.type) {
      case "text_delta":
        return text(update.delta) === undefined
          ? []
          : [
              output({
                sessionUpdate: "agent_message_chunk",
                messageId: `${message}:${index}`,
                content: { type: "text", text: update.delta }
              })
            ]
      case "thinking_delta":
        return text(update.delta) === undefined
          ? []
          : [
              output({
                sessionUpdate: "agent_thought_chunk",
                content: { type: "text", text: update.delta }
              })
            ]
      case "toolcall_start":
        return typeof update.id === "string"
          ? [
              output({
                sessionUpdate: "tool_call",
                status: "pending",
                rawInput: {},
                ...tool(update.id, String(update.toolName), {})
              })
            ]
          : []
      case "toolcall_end": {
        const call = record(update.toolCall)
        if (typeof call.id !== "string") return []
        const args = record(call.arguments)
        return [
          output({
            sessionUpdate: "tool_call_update",
            rawInput: args,
            ...tool(call.id, String(call.name), args)
          })
        ]
      }
      default:
        return []
    }
  }

  const finished = (assistant: Record<string, unknown>): ReadonlyArray<MappedEvent> => {
    const stopReason = typeof assistant.stopReason === "string" ? assistant.stopReason : "stop"
    const errorMessage = text(assistant.errorMessage)
    outcome = { stopReason, ...(errorMessage === undefined ? {} : { errorMessage }) }
    const usage = record(assistant.usage)
    totals.input += finite(usage.input)
    totals.cacheRead += finite(usage.cacheRead)
    totals.output += finite(usage.output)
    totals.reasoning += finite(usage.reasoning)
    totals.total += finite(usage.totalTokens)
    const size = contextWindow()
    return [
      updated({
        sessionUpdate: "usage_update",
        // The context this response used: everything it read plus what it wrote.
        used: finite(usage.totalTokens),
        ...(size === undefined ? {} : { size }),
        inputTokens: totals.input,
        cachedInputTokens: totals.cacheRead,
        outputTokens: totals.output,
        reasoningOutputTokens: totals.reasoning,
        totalTokens: totals.total
      })
    ]
  }

  const map = (event: Record<string, unknown>): ReadonlyArray<MappedEvent> => {
    switch (event.type) {
      case "message_start": {
        const started = record(event.message)
        if (started.role === "assistant") {
          messages += 1
          message = `pi-${typeof started.timestamp === "number" ? started.timestamp : 0}-${messages}`
        }
        return []
      }
      case "message_update":
        return streaming(record(event.assistantMessageEvent))
      case "message_end": {
        const ended = record(event.message)
        return ended.role === "assistant" ? finished(ended) : []
      }
      case "tool_execution_start": {
        const id = String(event.toolCallId)
        const args = record(event.args)
        return [
          output({
            sessionUpdate: "tool_call_update",
            status: "in_progress",
            rawInput: args,
            ...tool(id, String(event.toolName), args)
          })
        ]
      }
      case "tool_execution_update": {
        const partial = resultText(record(event.partialResult))
        return partial === undefined
          ? []
          : [
              output({
                sessionUpdate: "tool_call_update",
                toolCallId: String(event.toolCallId),
                content: textContent(partial)
              })
            ]
      }
      case "tool_execution_end": {
        const id = String(event.toolCallId)
        const known = tools.get(id) ?? { name: String(event.toolName), args: {} }
        tools.delete(id)
        const result = record(event.result)
        const failed = event.isError === true
        const change = failed ? {} : fileChange(known.name, known.args, result)
        const structured = record(result.structuredContent)
        return [
          output({
            sessionUpdate: "tool_call_update",
            toolCallId: id,
            status: failed ? "failed" : "completed",
            content: [
              ...textContent(resultText(result)),
              ...("content" in change ? change.content : [])
            ],
            ...("diffStats" in change ? { diffStats: change.diffStats } : {}),
            ...(typeof structured.exit_code === "number" ? { exitCode: structured.exit_code } : {}),
            rawOutput: result.details ?? result.structuredContent ?? null
          })
        ]
      }
      case "session_info_changed":
        return typeof event.name === "string"
          ? [updated({ sessionUpdate: "session_info_update", title: event.name })]
          : []
      case "compaction_start":
        compactions += 1
        return [
          output({
            sessionUpdate: "context_compaction",
            compactionId: `pi-${compactions}`,
            status: "started"
          })
        ]
      case "compaction_end":
        return [
          output({
            sessionUpdate: "context_compaction",
            compactionId: `pi-${compactions}`,
            status: "completed"
          })
        ]
      default:
        return []
    }
  }

  return {
    map,
    outcome: () => outcome,
    startRun: () => {
      outcome = undefined
    }
  }
}
