// Pure translator from server EventEnvelopes to the discriminated session
// stream events the UI consumes. Ports the payload parsing from the Swift
// ServerSessionTransport + ACPKit SessionUpdate decoding: session.output
// events carry raw ACP session updates (agent_message_chunk, tool_call, plan,
// ...) as the primary shape, with the legacy `{role, text}` conversation
// payload still accepted; session.updated carries stopReason/modeId/
// configOptions objects plus raw session_info_update/usage_update.
import { decode, type EventEnvelope, PromptQueueItem, SessionConfigOption } from "@herdman/api"
import { Schema } from "effect"

export interface ToolCallInfo {
  toolCallId: string
  title?: string
  kind?: string
  status?: string
  diffStats?: DiffStatInfo[]
  parentToolCallId?: string
}

export interface DiffStatInfo {
  path: string
  added: number
  removed: number
}

export interface PlanEntryInfo {
  content: string
  priority?: string
  status: string
}

export interface CommandInfo {
  name: string
  description: string
  hint?: string
}

export interface UsageInfo {
  used?: number
  size?: number
  costAmount?: number
  costCurrency?: string
}

export type SessionStreamEvent =
  | { type: "textChunk"; role: "user" | "assistant"; text: string; messageId?: string }
  | { type: "thoughtChunk"; text: string }
  | { type: "toolCall"; call: ToolCallInfo }
  | { type: "toolCallUpdate"; call: ToolCallInfo }
  | { type: "planUpdated"; entries: PlanEntryInfo[] }
  | { type: "commandsChanged"; commands: CommandInfo[] }
  | { type: "usageChanged"; usage: UsageInfo }
  | { type: "queueUpdated"; queue: readonly PromptQueueItem[] }
  | { type: "finished"; stopReason: string }
  | { type: "modeChanged"; modeId: string }
  | { type: "configOptionsChanged"; configOptions: readonly SessionConfigOption[] }
  | { type: "failed"; message: string }

const decodeQueue = decode(Schema.Array(PromptQueueItem))
const decodeConfigOptions = decode(Schema.Array(SessionConfigOption))

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value != null && !Array.isArray(value)
}

function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined
}

function numberOrUndefined(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}

// ACP content blocks: `{ type: "text", text }` carries the visible text.
function textFromContent(content: unknown): string | undefined {
  if (!isRecord(content)) return undefined
  if (content.type !== "text") return undefined
  return stringOrUndefined(content.text)
}

function promptQueueFrom(payload: Record<string, unknown>): readonly PromptQueueItem[] {
  try {
    return decodeQueue(payload.queue ?? [])
  } catch {
    return []
  }
}

function toolCallFrom(payload: Record<string, unknown>): ToolCallInfo | undefined {
  const toolCallId = stringOrUndefined(payload.toolCallId)
  if (toolCallId == null) return undefined
  return {
    toolCallId,
    title: stringOrUndefined(payload.title),
    kind: stringOrUndefined(payload.kind),
    status: stringOrUndefined(payload.status),
    diffStats: diffStatsFrom(payload.diffStats),
    parentToolCallId: stringOrUndefined(payload.parentToolCallId)
  }
}

// Streamed cumulative per-path added/removed line counts; malformed entries
// are dropped rather than failing the event.
function diffStatsFrom(value: unknown): DiffStatInfo[] | undefined {
  if (!Array.isArray(value)) return undefined
  const stats: DiffStatInfo[] = []
  for (const entry of value) {
    if (!isRecord(entry)) continue
    const path = stringOrUndefined(entry.path)
    const added = numberOrUndefined(entry.added)
    const removed = numberOrUndefined(entry.removed)
    if (path == null || added == null || removed == null) continue
    stats.push({ added, path, removed })
  }
  return stats.length > 0 ? stats : undefined
}

function planEntriesFrom(payload: Record<string, unknown>): PlanEntryInfo[] {
  if (!Array.isArray(payload.entries)) return []
  const entries: PlanEntryInfo[] = []
  for (const entry of payload.entries) {
    if (!isRecord(entry)) continue
    const content = stringOrUndefined(entry.content)
    if (content == null) continue
    entries.push({
      content,
      priority: stringOrUndefined(entry.priority),
      status: stringOrUndefined(entry.status) ?? "pending"
    })
  }
  return entries
}

function commandsFrom(payload: Record<string, unknown>): CommandInfo[] {
  if (!Array.isArray(payload.availableCommands)) return []
  const commands: CommandInfo[] = []
  for (const command of payload.availableCommands) {
    if (!isRecord(command)) continue
    const name = stringOrUndefined(command.name)
    if (name == null) continue
    commands.push({
      name,
      description: stringOrUndefined(command.description) ?? "",
      hint: isRecord(command.input) ? stringOrUndefined(command.input.hint) : undefined
    })
  }
  return commands
}

function usageFrom(payload: Record<string, unknown>): UsageInfo {
  const cost = isRecord(payload.cost) ? payload.cost : undefined
  return {
    used: numberOrUndefined(payload.used),
    size: numberOrUndefined(payload.size),
    costAmount: cost != null ? numberOrUndefined(cost.amount) : undefined,
    costCurrency: cost != null ? stringOrUndefined(cost.currency) : undefined
  }
}

// Translates a raw ACP session update (payload.sessionUpdate discriminator).
function rawUpdateEvents(payload: Record<string, unknown>): SessionStreamEvent[] {
  const messageId = stringOrUndefined(payload.messageId)
  switch (payload.sessionUpdate) {
    case "agent_message_chunk": {
      const text = textFromContent(payload.content)
      return text != null && text !== ""
        ? [{ type: "textChunk", role: "assistant", text, messageId }]
        : []
    }
    case "user_message_chunk": {
      const text = textFromContent(payload.content)
      return text != null && text !== ""
        ? [{ type: "textChunk", role: "user", text, messageId }]
        : []
    }
    case "agent_thought_chunk": {
      const text = textFromContent(payload.content)
      return text != null && text !== "" ? [{ type: "thoughtChunk", text }] : []
    }
    case "tool_call": {
      const call = toolCallFrom(payload)
      return call != null ? [{ type: "toolCall", call }] : []
    }
    case "tool_call_update": {
      const call = toolCallFrom(payload)
      return call != null ? [{ type: "toolCallUpdate", call }] : []
    }
    case "plan":
      return [{ type: "planUpdated", entries: planEntriesFrom(payload) }]
    case "available_commands_update":
      return [{ type: "commandsChanged", commands: commandsFrom(payload) }]
    case "current_mode_update": {
      const modeId = stringOrUndefined(payload.currentModeId)
      return modeId != null ? [{ type: "modeChanged", modeId }] : []
    }
    case "usage_update":
      return [{ type: "usageChanged", usage: usageFrom(payload) }]
    default:
      return []
  }
}

// Legacy `{ role, text, messageId? }` conversation payload on session.output.
function textUpdatesFrom(payload: Record<string, unknown>): SessionStreamEvent[] {
  const role = payload.role
  const text = payload.text
  if (typeof role !== "string" || typeof text !== "string" || text === "") return []
  if (role !== "assistant" && role !== "user") return []
  const messageId = stringOrUndefined(payload.messageId)
  return [{ type: "textChunk", role, text, messageId }]
}

function metadataUpdatesFrom(payload: Record<string, unknown>): SessionStreamEvent[] {
  if (payload.configOptions !== undefined) {
    try {
      return [
        { type: "configOptionsChanged", configOptions: decodeConfigOptions(payload.configOptions) }
      ]
    } catch {
      // Fall through to the mode check, matching the Swift decoder's
      // nil-on-failure behavior.
    }
  }
  if (typeof payload.modeId === "string") {
    return [{ type: "modeChanged", modeId: payload.modeId }]
  }
  return []
}

// Splits one envelope into zero or more session stream events. A payload
// carrying a raw ACP `sessionUpdate` short-circuits everything else, exactly
// like the Swift transport.
export function sessionStreamEvents(event: EventEnvelope): SessionStreamEvent[] {
  const payload = isRecord(event.payload) ? event.payload : {}

  if (typeof payload.sessionUpdate === "string") {
    return rawUpdateEvents(payload)
  }

  switch (event.kind) {
    case "session.queue.updated":
      return [{ type: "queueUpdated", queue: promptQueueFrom(payload) }]
    case "session.output":
      return textUpdatesFrom(payload)
    case "session.updated": {
      if (typeof payload.stopReason === "string") {
        return [{ type: "finished", stopReason: payload.stopReason }]
      }
      return metadataUpdatesFrom(payload)
    }
    case "session.error": {
      const message =
        typeof payload.message === "string" ? payload.message : "The server reported an error."
      return [{ type: "failed", message }]
    }
    default:
      return []
  }
}
