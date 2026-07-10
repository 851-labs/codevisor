// Pure translator from server EventEnvelopes to the discriminated session
// stream events the UI consumes. Ports the payload parsing from the Swift
// ServerSessionTransport + ACPKit SessionUpdate decoding: session.output
// events carry raw ACP session updates (agent_message_chunk, tool_call, plan,
// ...) as the primary shape, with the legacy `{role, text}` conversation
// payload still accepted; session.updated carries stopReason/modeId/
// configOptions objects plus raw session_info_update/usage_update.
import {
  AttachmentRef,
  decode,
  type EventEnvelope,
  PromptQueueItem,
  SessionConfigOption,
  SessionGoal,
  type AttachmentRef as AttachmentRefInfo,
  type SessionGoal as SessionGoalType
} from "@herdman/api"
import { Schema } from "effect"

export interface ToolCallInfo {
  toolCallId: string
  title?: string
  kind?: string
  status?: string
  content?: ToolCallContentInfo[]
  diffStats?: DiffStatInfo[]
  rawInput?: unknown
  rawOutput?: unknown
  parentToolCallId?: string
}

export type MessagePhase = "commentary" | "final"

export type ToolCallContentInfo =
  | { type: "content"; content: ContentBlockInfo }
  | { type: "diff"; path: string; oldText?: string; newText: string }
  | { type: "terminal"; terminalId: string }

export type ContentBlockInfo =
  | { type: "text"; text: string }
  | {
      type: "resource_link"
      name: string
      uri: string
      title?: string
      description?: string
      mimeType?: string
      size?: number
    }

export interface DiffStatInfo {
  path: string
  added: number
  removed: number
}

export interface PlanEntryInfo {
  content: string
  priority?: string
  status: PlanEntryStatusInfo
}

export type PlanEntryStatusInfo = "pending" | "in_progress" | "completed"

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

export interface RetryStatusInfo {
  attempt: number
  of: number
}

export interface BackgroundTaskInfo {
  id: string
  description: string
  status: string
  taskType: string
  toolUseId?: string
  terminalKey?: string
  readOnly?: boolean
}

export interface QuestionResolutionInfo {
  questionId: string
  outcome: string
  questions: QuestionSpecInfo[]
  answers?: Record<string, QuestionAnswerInfo>
}

export interface QuestionRequestInfo {
  questionId: string
  message?: string
  questions: QuestionSpecInfo[]
  autoResolutionMs?: number
}

export interface QuestionSpecInfo {
  id: string
  header?: string
  question: string
  options: QuestionOptionInfo[]
  multiSelect?: boolean
  allowsOther: boolean
  isSecret?: boolean
}

export interface QuestionOptionInfo {
  id?: string
  label: string
  description?: string
}

export interface QuestionAnswerInfo {
  answers: string[]
  note?: string
}

export type SessionStreamEvent =
  | {
      type: "textChunk"
      role: "user" | "assistant"
      text: string
      messageId?: string
      parentToolCallId?: string
      phase?: MessagePhase
      attachments?: readonly AttachmentRefInfo[]
    }
  | { type: "thoughtChunk"; text: string; parentToolCallId?: string }
  | { type: "toolCall"; call: ToolCallInfo }
  | { type: "toolCallUpdate"; call: ToolCallInfo }
  | { type: "planDocumentUpdated"; markdown: string }
  | { type: "planUpdated"; entries: PlanEntryInfo[] }
  | { type: "questionAsked"; request: QuestionRequestInfo }
  | { type: "questionResolved"; resolution: QuestionResolutionInfo }
  | { type: "backgroundTasksChanged"; tasks: BackgroundTaskInfo[] }
  | { type: "commandsChanged"; commands: CommandInfo[] }
  | { type: "usageChanged"; usage: UsageInfo }
  | { type: "goalChanged"; goal: SessionGoalType }
  | { type: "goalCleared" }
  | { type: "queueUpdated"; queue: readonly PromptQueueItem[] }
  | { type: "retrying"; retry: RetryStatusInfo }
  | { type: "finished"; stopReason: string; stopDetail?: string }
  | { type: "modeChanged"; modeId: string }
  | { type: "configOptionsChanged"; configOptions: readonly SessionConfigOption[] }
  | { type: "failed"; message: string }

const decodeQueue = decode(Schema.Array(PromptQueueItem))
const decodeConfigOptions = decode(Schema.Array(SessionConfigOption))
const decodeGoal = decode(SessionGoal)
const decodeAttachments = decode(Schema.Array(AttachmentRef))

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value != null && !Array.isArray(value)
}

function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined
}

function numberOrUndefined(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}

function retryStatusFrom(payload: Record<string, unknown>): RetryStatusInfo | undefined {
  if (!isRecord(payload.retrying)) return undefined
  const attempt = numberOrUndefined(payload.retrying.attempt)
  const of = numberOrUndefined(payload.retrying.of)
  if (attempt == null || of == null || !Number.isInteger(attempt) || !Number.isInteger(of)) {
    return undefined
  }
  return { attempt, of }
}

function booleanOrUndefined(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined
}

function phaseOrUndefined(value: unknown): MessagePhase | undefined {
  return value === "commentary" || value === "final" ? value : undefined
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

function attachmentsFrom(value: unknown): readonly AttachmentRefInfo[] | undefined {
  if (value === undefined) return undefined
  try {
    const attachments = decodeAttachments(value)
    return attachments.length === 0 ? undefined : attachments
  } catch {
    return undefined
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
    content: toolCallContentFrom(payload.content),
    diffStats: diffStatsFrom(payload.diffStats),
    rawInput: payload.rawInput,
    rawOutput: payload.rawOutput,
    parentToolCallId: stringOrUndefined(payload.parentToolCallId)
  }
}

function contentBlockFrom(value: unknown): ContentBlockInfo | undefined {
  if (!isRecord(value)) return undefined
  switch (value.type) {
    case "text": {
      const text = stringOrUndefined(value.text)
      return text == null ? undefined : { type: "text", text }
    }
    case "resource_link": {
      const name = stringOrUndefined(value.name)
      const uri = stringOrUndefined(value.uri)
      if (name == null || uri == null) return undefined
      return {
        type: "resource_link",
        name,
        uri,
        title: stringOrUndefined(value.title),
        description: stringOrUndefined(value.description),
        mimeType: stringOrUndefined(value.mimeType),
        size: numberOrUndefined(value.size)
      }
    }
    default:
      return undefined
  }
}

// Tool call content is lenient like ACPKit: malformed or future elements are
// skipped so one unknown block does not drop the entire tool-call update.
function toolCallContentFrom(value: unknown): ToolCallContentInfo[] | undefined {
  if (!Array.isArray(value)) return undefined
  const content: ToolCallContentInfo[] = []
  for (const entry of value) {
    if (!isRecord(entry)) continue
    switch (entry.type) {
      case "content": {
        const block = contentBlockFrom(entry.content)
        if (block != null) content.push({ type: "content", content: block })
        break
      }
      case "diff": {
        const path = stringOrUndefined(entry.path)
        const newText = stringOrUndefined(entry.newText)
        if (path == null || newText == null) break
        content.push({
          type: "diff",
          path,
          oldText: stringOrUndefined(entry.oldText),
          newText
        })
        break
      }
      case "terminal": {
        const terminalId = stringOrUndefined(entry.terminalId)
        if (terminalId != null) content.push({ type: "terminal", terminalId })
        break
      }
    }
  }
  return content.length > 0 ? content : undefined
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
      status: planEntryStatus(stringOrUndefined(entry.status))
    })
  }
  return entries
}

function planEntryStatus(status: string | undefined): PlanEntryStatusInfo {
  switch (status) {
    case "completed":
      return "completed"
    case "inProgress":
    case "in_progress":
      return "in_progress"
    default:
      return "pending"
  }
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

function goalFrom(value: unknown): SessionGoalType | undefined {
  try {
    return decodeGoal(value)
  } catch {
    return undefined
  }
}

function backgroundTasksFrom(payload: Record<string, unknown>): BackgroundTaskInfo[] {
  if (!Array.isArray(payload.backgroundTasks)) return []
  const tasks: BackgroundTaskInfo[] = []
  for (const task of payload.backgroundTasks) {
    if (!isRecord(task)) continue
    const id = stringOrUndefined(task.id)
    const description = stringOrUndefined(task.description)
    const status = stringOrUndefined(task.status)
    const taskType = stringOrUndefined(task.taskType)
    if (id == null || description == null || status == null || taskType == null) continue
    tasks.push({
      id,
      description,
      status,
      taskType,
      toolUseId: stringOrUndefined(task.toolUseId),
      terminalKey: stringOrUndefined(task.terminalKey),
      readOnly: booleanOrUndefined(task.readOnly)
    })
  }
  return tasks
}

function questionResolutionFrom(
  payload: Record<string, unknown>
): QuestionResolutionInfo | undefined {
  const questionId = stringOrUndefined(payload.questionId)
  const outcome = stringOrUndefined(payload.outcome)
  if (questionId == null || outcome == null || !Array.isArray(payload.questions)) return undefined
  const questions: QuestionSpecInfo[] = []
  for (const question of payload.questions) {
    const parsed = questionSpecFrom(question)
    if (parsed != null) questions.push(parsed)
  }
  const answers: Record<string, QuestionAnswerInfo> = {}
  if (isRecord(payload.answers)) {
    for (const [id, value] of Object.entries(payload.answers)) {
      if (!isRecord(value) || !Array.isArray(value.answers)) continue
      const selected = value.answers.filter((entry): entry is string => typeof entry === "string")
      answers[id] = { answers: selected, note: stringOrUndefined(value.note) }
    }
  }
  return {
    questionId,
    outcome,
    questions,
    answers: Object.keys(answers).length > 0 ? answers : undefined
  }
}

function questionOptionFrom(value: unknown): QuestionOptionInfo | undefined {
  if (!isRecord(value)) return undefined
  const label = stringOrUndefined(value.label)
  if (label == null) return undefined
  return {
    id: stringOrUndefined(value.id),
    label,
    description: stringOrUndefined(value.description)
  }
}

function questionSpecFrom(value: unknown): QuestionSpecInfo | undefined {
  if (!isRecord(value)) return undefined
  const id = stringOrUndefined(value.id)
  const question = stringOrUndefined(value.question)
  if (id == null || question == null || !Array.isArray(value.options)) return undefined
  return {
    id,
    header: stringOrUndefined(value.header),
    question,
    options: value.options.flatMap((option) => {
      const parsed = questionOptionFrom(option)
      return parsed == null ? [] : [parsed]
    }),
    multiSelect: booleanOrUndefined(value.multiSelect),
    allowsOther: value.allowsOther === true,
    isSecret: booleanOrUndefined(value.isSecret)
  }
}

function questionRequestFrom(payload: Record<string, unknown>): QuestionRequestInfo | undefined {
  const questionId = stringOrUndefined(payload.questionId)
  if (questionId == null || !Array.isArray(payload.questions)) return undefined
  const questions = payload.questions.flatMap((question) => {
    const parsed = questionSpecFrom(question)
    return parsed == null ? [] : [parsed]
  })
  if (questions.length === 0) return undefined
  return {
    questionId,
    message: stringOrUndefined(payload.message),
    questions,
    autoResolutionMs: numberOrUndefined(payload.autoResolutionMs)
  }
}

// Translates a raw ACP session update (payload.sessionUpdate discriminator).
function rawUpdateEvents(payload: Record<string, unknown>): SessionStreamEvent[] {
  const messageId = stringOrUndefined(payload.messageId)
  const parentToolCallId = stringOrUndefined(payload.parentToolCallId)
  const phase = phaseOrUndefined(payload.phase)
  switch (payload.sessionUpdate) {
    case "agent_message_chunk": {
      const text = textFromContent(payload.content) ?? ""
      return text !== "" || phase != null
        ? [{ type: "textChunk", role: "assistant", text, messageId, parentToolCallId, phase }]
        : []
    }
    case "user_message_chunk": {
      const text = textFromContent(payload.content)
      return text != null && text !== ""
        ? [{ type: "textChunk", role: "user", text, messageId, parentToolCallId }]
        : []
    }
    case "agent_thought_chunk": {
      const text = textFromContent(payload.content)
      return text != null && text !== "" ? [{ type: "thoughtChunk", text, parentToolCallId }] : []
    }
    case "tool_call": {
      const call = toolCallFrom(payload)
      return call != null ? [{ type: "toolCall", call }] : []
    }
    case "tool_call_update": {
      const call = toolCallFrom(payload)
      return call != null ? [{ type: "toolCallUpdate", call }] : []
    }
    case "plan_document": {
      const markdown = stringOrUndefined(payload.markdown)
      return markdown != null && markdown !== "" ? [{ type: "planDocumentUpdated", markdown }] : []
    }
    case "plan":
      return [{ type: "planUpdated", entries: planEntriesFrom(payload) }]
    case "question": {
      const request = questionRequestFrom(payload)
      return request != null ? [{ type: "questionAsked", request }] : []
    }
    case "question_resolved": {
      const resolution = questionResolutionFrom(payload)
      return resolution != null ? [{ type: "questionResolved", resolution }] : []
    }
    case "available_commands_update":
      return [{ type: "commandsChanged", commands: commandsFrom(payload) }]
    case "current_mode_update": {
      const modeId = stringOrUndefined(payload.currentModeId)
      return modeId != null ? [{ type: "modeChanged", modeId }] : []
    }
    case "usage_update":
      return [{ type: "usageChanged", usage: usageFrom(payload) }]
    case "goal_update": {
      const goal = goalFrom(payload.goal)
      return goal == null ? [] : [{ type: "goalChanged", goal }]
    }
    case "goal_cleared":
      return [{ type: "goalCleared" }]
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
  const attachments = attachmentsFrom(payload.attachments)
  return [{ type: "textChunk", role, text, messageId, attachments }]
}

function metadataUpdatesFrom(payload: Record<string, unknown>): SessionStreamEvent[] {
  if (payload.goal !== undefined) {
    const goal = goalFrom(payload.goal)
    return goal == null ? [] : [{ type: "goalChanged", goal }]
  }
  if (payload.goalCleared === true) {
    return [{ type: "goalCleared" }]
  }
  if (Array.isArray(payload.backgroundTasks)) {
    return [{ type: "backgroundTasksChanged", tasks: backgroundTasksFrom(payload) }]
  }
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
      const retry = retryStatusFrom(payload)
      if (retry != null) return [{ type: "retrying", retry }]
      if (typeof payload.stopReason === "string") {
        return [
          {
            type: "finished",
            stopReason: payload.stopReason,
            stopDetail: stringOrUndefined(payload.stopDetail)
          }
        ]
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
