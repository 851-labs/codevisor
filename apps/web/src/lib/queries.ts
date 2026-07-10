// TanStack Query layer: query keys, hooks, and the WS-driven cache
// maintenance that keeps them live. The event feed is invalidation-shaped for
// CRUD resources; session output streams are merged into the session-detail
// cache directly (no refetch per chunk), deduped against the detail's
// eventCursor exactly like the Swift client's replay handling.
import type {
  ConversationItem,
  BranchDiffTotals,
  CreateSessionRequest,
  CreateProjectRequest,
  CreateWorktreeRequest,
  EventEnvelope,
  AttachmentRef,
  GoalStatus,
  QuestionAnswerEntry,
  SessionConfigOption,
  SessionDetail,
  SessionGoal,
  UpdateSessionRequest,
  UpdateProjectRequest
} from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import { QueryClient, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"

import { useApi } from "./api"
import { foldConversation } from "./conversation"
import type { EventSocket } from "./events"
import { trackRunningSessions } from "./running-sessions"
import { projectFolderPath } from "./client"
import {
  applyWorktreeSetupEventForName,
  applyWorktreeSetupEventForSession,
  worktreeSetupUpdateForName,
  worktreeSetupUpdateForSession,
  type SessionSetupPhaseInfo
} from "./session-setup"
import {
  type BackgroundTaskInfo,
  type CommandInfo,
  type MessagePhase,
  type PlanEntryInfo,
  type RetryStatusInfo,
  type QuestionRequestInfo,
  type QuestionResolutionInfo,
  type SessionStreamEvent,
  sessionStreamEvents,
  type ToolCallInfo,
  type UsageInfo
} from "./session-events"

export const queryKeys = {
  projects: ["projects"] as const,
  sessions: ["sessions"] as const,
  session: (id: string) => ["session", id] as const,
  sessionBranchDiff: (id: string) => ["session-branch-diff", id] as const,
  harnesses: ["harnesses"] as const,
  capabilities: (cwd: string) => ["capabilities", cwd] as const
}

// Live per-assistant-turn metadata accumulated from the raw ACP stream
// (thoughts, tool calls, plan). Keyed by the conversation item id of the
// assistant message it belongs to; historical turns fetched over REST are
// text-only (the harness owns the full transcript), matching the Swift app.
export interface TurnMeta {
  startedAt: string
  endedAt?: string
  thoughts: string
  toolCalls: ToolCallInfo[]
  entries: TranscriptEntryInfo[]
  subagents: Record<string, SubagentTranscriptInfo>
  textPhases: Record<string, MessagePhase>
  nextTextId: number
  isThinking?: boolean
  retryStatus?: RetryStatusInfo
  stopReason?: string
  stopDetail?: string
  planDocument?: string
  planBoundary?: number
  plan?: PlanEntryInfo[]
}

export type TranscriptEntryInfo =
  | { type: "text"; id: string; markdown: string }
  | { type: "tool"; call: ToolCallInfo }

export interface SubagentTranscriptInfo {
  entries: TranscriptEntryInfo[]
  isThinking: boolean
  nextTextId: number
}

// The session-detail cache: the server payload plus stream-derived fields the
// REST shape doesn't carry (a live error banner, current mode, slash
// commands, usage, and per-turn worked metadata).
export interface SessionDetailCache extends SessionDetail {
  streamError?: string
  currentModeId?: string
  availableCommands?: CommandInfo[]
  liveUsage?: UsageInfo
  goal?: SessionGoal
  configOptions?: readonly SessionConfigOption[]
  sessionPlan?: PlanEntryInfo[]
  setupPhases?: SessionSetupPhaseInfo[]
  backgroundTasks?: BackgroundTaskInfo[]
  runningSubagentToolCallIds?: string[]
  pendingQuestion?: QuestionRequestInfo
  turnMeta?: Record<string, TurnMeta>
}

function isOptimisticUserItem(item: ConversationItem): boolean {
  return item.role === "user" && (item as { optimistic?: boolean }).optimistic === true
}

function attachmentKey(attachments: readonly AttachmentRef[] | undefined): string {
  return (attachments ?? []).map((attachment) => attachment.fileId).join("\0")
}

function isSameUserPrompt(
  item: Pick<ConversationItem, "role" | "text" | "attachments">,
  text: string,
  attachments: readonly AttachmentRef[] | undefined
): boolean {
  return (
    item.role === "user" &&
    item.text === text &&
    attachmentKey(item.attachments) === attachmentKey(attachments)
  )
}

function hasOptimisticUserPrompt(
  detail: SessionDetailCache,
  text: string,
  attachments: readonly AttachmentRef[] | undefined
): boolean {
  return detail.conversation.some(
    (item) => isOptimisticUserItem(item) && isSameUserPrompt(item, text, attachments)
  )
}

export function canAppendOptimisticUserPrompt(detail: SessionDetailCache): boolean {
  return detail.conversation.every((item) => !item.isGenerating)
}

export function withOptimisticUserPrompt(
  detail: SessionDetailCache,
  text: string,
  attachments: readonly AttachmentRef[] | undefined
): SessionDetailCache {
  if (!canAppendOptimisticUserPrompt(detail)) return detail
  const trimmed = text.trim()
  const startedAt = isoTimestamp()
  const user: ConversationItem & { optimistic: true } = {
    id: `optimistic:${crypto.randomUUID()}`,
    role: "user",
    messageId: undefined,
    text: trimmed,
    createdAt: startedAt,
    isGenerating: false,
    optimistic: true,
    ...(attachments == null || attachments.length === 0 ? {} : { attachments: [...attachments] })
  }
  const assistant: ConversationItem = {
    id: `optimistic-assistant:${crypto.randomUUID()}`,
    role: "assistant",
    messageId: undefined,
    text: "",
    createdAt: startedAt,
    isGenerating: true
  }
  return {
    ...detail,
    streamError: undefined,
    conversation: [...detail.conversation, user, assistant],
    turnMeta: {
      ...detail.turnMeta,
      [assistant.id]: { ...initialTurnMeta(startedAt), isThinking: true }
    }
  }
}

function applySetupEvent(detail: SessionDetailCache, event: EventEnvelope): SessionDetailCache {
  if (event.kind !== "worktree.setup") return detail
  const sessionId = detail.session.id
  const isSessionSetupEvent =
    sessionId != null && worktreeSetupUpdateForSession(event, sessionId) != null
  if (
    !isSessionSetupEvent &&
    worktreeSetupUpdateForName(event, detail.session.worktreeName) == null
  ) {
    return detail
  }
  return {
    ...detail,
    setupPhases: isSessionSetupEvent
      ? applyWorktreeSetupEventForSession(detail.setupPhases ?? [], event, sessionId)
      : applyWorktreeSetupEventForName(detail.setupPhases ?? [], event, detail.session.worktreeName)
  }
}

// ---------------------------------------------------------------------------
// WS-driven cache maintenance
// ---------------------------------------------------------------------------

function generatingAssistantItem(detail: SessionDetailCache): ConversationItem | undefined {
  const last = detail.conversation[detail.conversation.length - 1]
  return last != null && last.role === "assistant" && last.isGenerating ? last : undefined
}

// Ensures a generating assistant item exists to host streamed content —
// thoughts and tool calls can arrive before the first message text.
function withGeneratingAssistant(
  detail: SessionDetailCache,
  createdAt: string = isoTimestamp()
): {
  detail: SessionDetailCache
  item: ConversationItem
} {
  const existing = generatingAssistantItem(detail)
  if (existing != null) return { detail, item: existing }
  const item: ConversationItem = {
    id: crypto.randomUUID(),
    role: "assistant",
    messageId: undefined,
    text: "",
    createdAt,
    isGenerating: true
  }
  return {
    detail: {
      ...detail,
      conversation: [...detail.conversation, item],
      streamError: undefined
    },
    item
  }
}

function updateTurnMeta(
  detail: SessionDetailCache,
  update: (meta: TurnMeta) => TurnMeta,
  createdAt?: string
): SessionDetailCache {
  const { detail: withItem, item } = withGeneratingAssistant(detail, createdAt)
  const current = withItem.turnMeta?.[item.id] ?? initialTurnMeta(item.createdAt)
  return {
    ...withItem,
    turnMeta: { ...withItem.turnMeta, [item.id]: update(current) }
  }
}

function updateTurnMetaById(
  detail: SessionDetailCache,
  itemId: string,
  update: (meta: TurnMeta) => TurnMeta
): SessionDetailCache {
  const item = detail.conversation.find((candidate) => candidate.id === itemId)
  const current = detail.turnMeta?.[itemId] ?? initialTurnMeta(item?.createdAt ?? isoTimestamp())
  return {
    ...detail,
    turnMeta: { ...detail.turnMeta, [itemId]: update(current) }
  }
}

function mainTool(meta: TurnMeta, toolCallId: string): ToolCallInfo | undefined {
  for (const entry of meta.entries) {
    if (entry.type === "tool" && entry.call.toolCallId === toolCallId) return entry.call
  }
  return meta.toolCalls.find((call) => call.toolCallId === toolCallId)
}

function subagentTool(meta: TurnMeta, toolCallId: string): ToolCallInfo | undefined {
  for (const bucket of Object.values(meta.subagents)) {
    for (const entry of bucket.entries) {
      if (entry.type === "tool" && entry.call.toolCallId === toolCallId) return entry.call
    }
  }
  return undefined
}

function ownsParent(meta: TurnMeta, parentToolCallId: string): boolean {
  return meta.subagents[parentToolCallId] != null || mainTool(meta, parentToolCallId) != null
}

function ownsTool(meta: TurnMeta, toolCallId: string): boolean {
  return mainTool(meta, toolCallId) != null || subagentTool(meta, toolCallId) != null
}

function ownerTurnId(
  detail: SessionDetailCache,
  predicate: (meta: TurnMeta) => boolean
): string | undefined {
  const turnMeta = detail.turnMeta
  if (turnMeta == null) return undefined
  for (const item of [...detail.conversation].reverse()) {
    const meta = turnMeta[item.id]
    if (meta != null && predicate(meta)) return item.id
  }
  return undefined
}

function updateOwnedOrActiveTurnMeta(
  detail: SessionDetailCache,
  predicate: (meta: TurnMeta) => boolean,
  update: (meta: TurnMeta) => TurnMeta,
  createdAt?: string
): SessionDetailCache {
  const itemId = ownerTurnId(detail, predicate)
  return itemId == null
    ? updateTurnMeta(detail, update, createdAt)
    : updateTurnMetaById(detail, itemId, update)
}

function initialTurnMeta(startedAt: string): TurnMeta {
  return {
    startedAt,
    thoughts: "",
    toolCalls: [],
    entries: [],
    subagents: {},
    textPhases: {},
    nextTextId: 0
  }
}

function textEntryIndex(id: string, entries: readonly TranscriptEntryInfo[]): number {
  return entries.findIndex((entry) => entry.type === "text" && entry.id === id)
}

function toolEntryIndex(toolCallId: string, entries: readonly TranscriptEntryInfo[]): number {
  return entries.findIndex((entry) => entry.type === "tool" && entry.call.toolCallId === toolCallId)
}

function appendTextEntry(
  entries: readonly TranscriptEntryInfo[],
  nextTextId: number,
  text: string,
  messageId?: string
): { entries: TranscriptEntryInfo[]; nextTextId: number; entryId?: string } {
  if (messageId != null) {
    const id = `acp:${messageId}`
    if (text === "") return { entries: [...entries], nextTextId, entryId: id }
    const index = textEntryIndex(id, entries)
    if (index !== -1) {
      const next = [...entries]
      const existing = next[index]
      if (existing?.type === "text") {
        next[index] = { ...existing, markdown: existing.markdown + text }
      }
      return { entries: next, nextTextId, entryId: id }
    }
    return { entries: [...entries, { type: "text", id, markdown: text }], nextTextId, entryId: id }
  }

  if (text === "") return { entries: [...entries], nextTextId }
  const last = entries[entries.length - 1]
  if (last?.type === "text") {
    const next = [...entries]
    next[next.length - 1] = { ...last, markdown: last.markdown + text }
    return { entries: next, nextTextId, entryId: last.id }
  }
  const id = `t${nextTextId}`
  return {
    entries: [...entries, { type: "text", id, markdown: text }],
    nextTextId: nextTextId + 1,
    entryId: id
  }
}

function mergeToolCall(
  existing: ToolCallInfo,
  call: ToolCallInfo,
  isUpdate: boolean
): ToolCallInfo {
  if (isUpdate) {
    return {
      ...existing,
      ...Object.fromEntries(Object.entries(call).filter(([, value]) => value !== undefined))
    } as ToolCallInfo
  }
  return {
    ...call,
    diffStats: call.diffStats ?? existing.diffStats,
    content: call.content ?? existing.content
  }
}

function upsertToolEntry(
  entries: readonly TranscriptEntryInfo[],
  call: ToolCallInfo,
  isUpdate: boolean
): TranscriptEntryInfo[] {
  const index = toolEntryIndex(call.toolCallId, entries)
  if (index === -1) return [...entries, { type: "tool", call }]
  const next = [...entries]
  const existing = next[index]
  if (existing?.type === "tool") {
    next[index] = { type: "tool", call: mergeToolCall(existing.call, call, isUpdate) }
  }
  return next
}

function updateSubagent(
  meta: TurnMeta,
  parentToolCallId: string,
  update: (bucket: SubagentTranscriptInfo) => SubagentTranscriptInfo
): TurnMeta {
  const current = meta.subagents[parentToolCallId] ?? {
    entries: [],
    isThinking: false,
    nextTextId: 0
  }
  return {
    ...meta,
    subagents: { ...meta.subagents, [parentToolCallId]: update(current) }
  }
}

function isSettled(call: ToolCallInfo): boolean {
  return call.status === "completed" || call.status === "failed" || call.status === "cancelled"
}

function settleEntries(
  entries: readonly TranscriptEntryInfo[],
  status: "completed" | "failed" | "cancelled"
): TranscriptEntryInfo[] {
  return entries.map((entry) => {
    if (entry.type !== "tool" || isSettled(entry.call)) return entry
    return { type: "tool", call: { ...entry.call, status } }
  })
}

function settledToolStatus(
  status: string | undefined
): "completed" | "failed" | "cancelled" | undefined {
  return status === "completed" || status === "failed" || status === "cancelled"
    ? status
    : undefined
}

function cascadeSettledSubagents(meta: TurnMeta, parentToolCallId: string): TurnMeta {
  const parent = mainTool(meta, parentToolCallId) ?? subagentTool(meta, parentToolCallId)
  const status = settledToolStatus(parent?.status)
  if (status == null || meta.subagents[parentToolCallId] == null) return meta

  const subagents = { ...meta.subagents }
  const queue = [parentToolCallId]
  const visited = new Set<string>()
  while (queue.length > 0) {
    const id = queue.pop()
    if (id == null || visited.has(id)) continue
    visited.add(id)
    const bucket = subagents[id]
    if (bucket == null) continue
    const entries = settleEntries(bucket.entries, status)
    subagents[id] = { ...bucket, isThinking: false, entries }
    for (const entry of entries) {
      if (entry.type === "tool" && subagents[entry.call.toolCallId] != null) {
        queue.push(entry.call.toolCallId)
      }
    }
  }
  return { ...meta, subagents }
}

function settleTurnMeta(
  meta: TurnMeta,
  status: "completed" | "failed" | "cancelled",
  endedAt: string,
  terminal?: { stopReason?: string; stopDetail?: string }
): TurnMeta {
  const subagents = Object.fromEntries(
    Object.entries(meta.subagents).map(([id, bucket]) => [
      id,
      { ...bucket, isThinking: false, entries: settleEntries(bucket.entries, status) }
    ])
  )
  return {
    ...meta,
    endedAt,
    isThinking: false,
    retryStatus: undefined,
    stopReason: terminal?.stopReason,
    stopDetail: terminal?.stopDetail,
    toolCalls: meta.toolCalls.map((call) => (isSettled(call) ? call : { ...call, status })),
    entries: settleEntries(meta.entries, status),
    subagents
  }
}

function answerText(questionId: string, resolution: QuestionResolutionInfo): string {
  const entry = resolution.answers?.[questionId]
  if (entry == null) return "No answer"
  const parts = [...entry.answers]
  if (entry.note != null && entry.note !== "") parts.push(entry.note)
  return parts.length === 0 ? "No answer" : parts.join(", ")
}

function syntheticQuestionCall(resolution: QuestionResolutionInfo): ToolCallInfo {
  const title =
    resolution.questions.length === 1
      ? (resolution.questions[0]?.question ?? "Answered a question")
      : resolution.questions.length === 0
        ? "Answered a question"
        : `Answered ${resolution.questions.length} questions`
  const body =
    resolution.questions.length === 1
      ? answerText(resolution.questions[0]?.id ?? "", resolution)
      : resolution.questions
          .map((question) => `${question.question}\n${answerText(question.id, resolution)}`)
          .join("\n\n")
  return {
    toolCallId: `question:${resolution.questionId}`,
    title,
    kind: "question",
    status: "completed",
    content: body === "" ? undefined : [{ type: "content", content: { type: "text", text: body } }]
  }
}

function appendTextChunk(
  detail: SessionDetailCache,
  chunk: Extract<SessionStreamEvent, { type: "textChunk" }>,
  createdAt: string = isoTimestamp()
): SessionDetailCache {
  if (chunk.role === "user") return appendUserChunk(detail, chunk, createdAt)

  if (chunk.role === "assistant" && chunk.parentToolCallId != null) {
    return updateOwnedOrActiveTurnMeta(
      detail,
      (meta) => ownsParent(meta, chunk.parentToolCallId ?? ""),
      (meta) =>
        updateSubagent(meta, chunk.parentToolCallId ?? "", (bucket) => {
          const appended = appendTextEntry(
            bucket.entries,
            bucket.nextTextId,
            chunk.text,
            chunk.messageId
          )
          return {
            ...bucket,
            isThinking: false,
            entries: appended.entries,
            nextTextId: appended.nextTextId
          }
        }),
      createdAt
    )
  }

  if (
    chunk.role === "assistant" &&
    chunk.text === "" &&
    chunk.phase != null &&
    chunk.messageId != null
  ) {
    const entryId = `acp:${chunk.messageId}`
    const existingTurnId = ownerTurnId(
      detail,
      (meta) => textEntryIndex(entryId, meta.entries) !== -1
    )
    if (existingTurnId != null) {
      return updateTurnMetaById(detail, existingTurnId, (meta) => ({
        ...meta,
        isThinking: false,
        retryStatus: undefined,
        textPhases: { ...meta.textPhases, [entryId]: chunk.phase ?? "commentary" }
      }))
    }
  }

  const conversation: ConversationItem[] = [...detail.conversation]
  const last = conversation[conversation.length - 1]
  // Assistant chunks always continue the running turn — only a user message
  // starts a new bubble (TranscriptReducer semantics). A change of (non-null)
  // ACP messageId is a message boundary WITHIN the turn: a paragraph break,
  // not a new bubble.
  const mergesIntoLast =
    chunk.role === "assistant" && last != null && last.role === "assistant" && last.isGenerating
  if (mergesIntoLast) {
    const isMessageBoundary =
      last.messageId != null && chunk.messageId != null && last.messageId !== chunk.messageId
    conversation[conversation.length - 1] = {
      ...last,
      text: last.text + (isMessageBoundary ? "\n\n" : "") + chunk.text,
      messageId: chunk.messageId ?? last.messageId
    }
  } else {
    conversation.push({
      id: crypto.randomUUID(),
      role: chunk.role,
      messageId: chunk.messageId,
      text: chunk.text,
      createdAt,
      isGenerating: chunk.role === "assistant",
      ...(chunk.attachments == null || chunk.attachments.length === 0
        ? {}
        : { attachments: [...chunk.attachments] })
    })
  }
  const withConversation = { ...detail, conversation, streamError: undefined }
  return updateTurnMeta(
    withConversation,
    (meta) => {
      const appended = appendTextEntry(meta.entries, meta.nextTextId, chunk.text, chunk.messageId)
      const textPhases =
        chunk.phase != null && appended.entryId != null
          ? { ...meta.textPhases, [appended.entryId]: chunk.phase }
          : meta.textPhases
      return {
        ...meta,
        isThinking: false,
        retryStatus: undefined,
        entries: appended.entries,
        nextTextId: appended.nextTextId,
        textPhases
      }
    },
    createdAt
  )
}

function appendUserChunk(
  detail: SessionDetailCache,
  chunk: Extract<SessionStreamEvent, { type: "textChunk" }>,
  createdAt: string
): SessionDetailCache {
  const trimmed = chunk.text.trim()
  const optimisticIndex = detail.conversation.findIndex(
    (item) => isOptimisticUserItem(item) && item.text === trimmed
  )
  if (optimisticIndex !== -1) {
    const conversation = [...detail.conversation]
    const optimistic = conversation[optimisticIndex]
    if (optimistic != null) {
      const attachments = chunk.attachments ?? optimistic.attachments
      conversation[optimisticIndex] = {
        id: optimistic.id,
        role: "user",
        messageId: chunk.messageId ?? optimistic.messageId,
        text: trimmed,
        createdAt: optimistic.createdAt,
        isGenerating: false,
        ...(attachments == null || attachments.length === 0
          ? {}
          : { attachments: [...attachments] })
      }
    }
    return { ...detail, conversation, streamError: undefined }
  }

  const last = detail.conversation[detail.conversation.length - 1]
  const previous = detail.conversation[detail.conversation.length - 2]
  if (
    last?.role === "assistant" &&
    last.isGenerating &&
    previous?.role === "user" &&
    previous.text === trimmed
  ) {
    if ((previous.attachments?.length ?? 0) === 0 && (chunk.attachments?.length ?? 0) > 0) {
      const conversation = [...detail.conversation]
      conversation[conversation.length - 2] = {
        ...previous,
        attachments: [...(chunk.attachments ?? [])]
      }
      return { ...detail, conversation }
    }
    return detail
  }

  const assistant: ConversationItem = {
    id: crypto.randomUUID(),
    role: "assistant",
    messageId: undefined,
    text: "",
    createdAt,
    isGenerating: true
  }
  const user: ConversationItem = {
    id: crypto.randomUUID(),
    role: "user",
    messageId: chunk.messageId,
    text: trimmed,
    createdAt,
    isGenerating: false,
    ...(chunk.attachments == null || chunk.attachments.length === 0
      ? {}
      : { attachments: [...chunk.attachments] })
  }
  return {
    ...detail,
    streamError: undefined,
    conversation: [...detail.conversation, user, assistant],
    turnMeta: {
      ...detail.turnMeta,
      [assistant.id]: { ...initialTurnMeta(createdAt), isThinking: true }
    }
  }
}

function upsertToolCall(
  detail: SessionDetailCache,
  call: ToolCallInfo,
  isUpdate: boolean,
  createdAt?: string
): SessionDetailCache {
  const updateMain = (meta: TurnMeta): TurnMeta => {
    const index = meta.toolCalls.findIndex((existing) => existing.toolCallId === call.toolCallId)
    const toolCalls =
      index === -1
        ? [...meta.toolCalls, call]
        : meta.toolCalls.map((existing, offset) =>
            offset === index ? mergeToolCall(existing, call, isUpdate) : existing
          )
    const entries = upsertToolEntry(meta.entries, call, isUpdate)
    const subagents =
      call.kind === "agent" && meta.subagents[call.toolCallId] == null
        ? {
            ...meta.subagents,
            [call.toolCallId]: { entries: [], isThinking: false, nextTextId: 0 }
          }
        : meta.subagents
    return cascadeSettledSubagents(
      { ...meta, isThinking: false, retryStatus: undefined, toolCalls, entries, subagents },
      call.toolCallId
    )
  }

  const parentToolCallId = call.parentToolCallId
  if (parentToolCallId != null) {
    return updateOwnedOrActiveTurnMeta(
      detail,
      (meta) => ownsParent(meta, parentToolCallId),
      (meta) => {
        let updated = updateSubagent(
          { ...meta, retryStatus: undefined },
          parentToolCallId,
          (bucket) => ({
            ...bucket,
            isThinking: isUpdate ? bucket.isThinking : false,
            entries: upsertToolEntry(bucket.entries, call, isUpdate)
          })
        )
        if (!isUpdate && call.kind === "agent" && updated.subagents[call.toolCallId] == null) {
          updated = {
            ...updated,
            subagents: {
              ...updated.subagents,
              [call.toolCallId]: { entries: [], isThinking: false, nextTextId: 0 }
            }
          }
        }
        return cascadeSettledSubagents(updated, call.toolCallId)
      },
      createdAt
    )
  }

  if (isUpdate) {
    const existingTurnId = ownerTurnId(detail, (meta) => ownsTool(meta, call.toolCallId))
    if (existingTurnId != null) {
      return updateTurnMetaById(detail, existingTurnId, (meta) => {
        if (mainTool(meta, call.toolCallId) != null) return updateMain(meta)
        const owner = Object.entries(meta.subagents).find(([, bucket]) =>
          bucket.entries.some(
            (entry) => entry.type === "tool" && entry.call.toolCallId === call.toolCallId
          )
        )
        if (owner == null) return updateMain(meta)
        const [parentId] = owner
        const updated = updateSubagent(meta, parentId, (bucket) => ({
          ...bucket,
          entries: upsertToolEntry(bucket.entries, call, true)
        }))
        return cascadeSettledSubagents(updated, call.toolCallId)
      })
    }
  }

  return updateTurnMeta(detail, updateMain, createdAt)
}

function finishGenerating(
  detail: SessionDetailCache,
  status: "completed" | "failed" | "cancelled" = "completed",
  endedAt: string = isoTimestamp(),
  terminal?: { stopReason?: string; stopDetail?: string }
): SessionDetailCache {
  return {
    ...detail,
    pendingQuestion: undefined,
    conversation: detail.conversation.map((item) =>
      item.isGenerating ? { ...item, isGenerating: false } : item
    ),
    turnMeta:
      detail.turnMeta == null
        ? undefined
        : Object.fromEntries(
            Object.entries(detail.turnMeta).map(([itemId, meta]) => [
              itemId,
              detail.conversation.find((item) => item.id === itemId && item.isGenerating) != null
                ? settleTurnMeta(meta, status, endedAt, terminal)
                : meta
            ])
          )
  }
}

function applySessionEvent(
  detail: SessionDetailCache,
  event: SessionStreamEvent,
  createdAt?: string
): SessionDetailCache {
  switch (event.type) {
    case "textChunk":
      return appendTextChunk(detail, event, createdAt)
    case "thoughtChunk":
      if (event.parentToolCallId != null) {
        return updateOwnedOrActiveTurnMeta(
          detail,
          (meta) => ownsParent(meta, event.parentToolCallId ?? ""),
          (meta) =>
            updateSubagent(
              { ...meta, retryStatus: undefined },
              event.parentToolCallId ?? "",
              (bucket) => ({
                ...bucket,
                isThinking: true
              })
            ),
          createdAt
        )
      }
      return updateTurnMeta(
        detail,
        (meta) => ({
          ...meta,
          retryStatus: undefined,
          isThinking: true,
          thoughts: meta.thoughts + event.text
        }),
        createdAt
      )
    case "toolCall":
      return upsertToolCall(detail, event.call, false, createdAt)
    case "toolCallUpdate":
      return upsertToolCall(detail, event.call, true, createdAt)
    case "planDocumentUpdated":
      return updateTurnMeta(
        detail,
        (meta) => ({
          ...meta,
          retryStatus: undefined,
          isThinking: false,
          planDocument: event.markdown,
          planBoundary: meta.entries.length
        }),
        createdAt
      )
    case "planUpdated":
      return updateTurnMeta(
        { ...detail, sessionPlan: event.entries },
        (meta) => ({ ...meta, retryStatus: undefined, plan: event.entries }),
        createdAt
      )
    case "questionAsked":
      return { ...detail, pendingQuestion: event.request }
    case "questionResolved":
      detail =
        detail.pendingQuestion?.questionId === event.resolution.questionId
          ? { ...detail, pendingQuestion: undefined }
          : detail
      if (event.resolution.outcome !== "answered") return detail
      return upsertToolCall(detail, syntheticQuestionCall(event.resolution), false, createdAt)
    case "backgroundTasksChanged": {
      const runningSubagentToolCallIds = event.tasks
        .filter((task) => task.taskType === "subagent" && task.toolUseId != null)
        .map((task) => task.toolUseId ?? "")
      return { ...detail, backgroundTasks: event.tasks, runningSubagentToolCallIds }
    }
    case "commandsChanged":
      return { ...detail, availableCommands: event.commands }
    case "usageChanged":
      return { ...detail, liveUsage: { ...detail.liveUsage, ...event.usage } }
    case "goalChanged":
      return { ...detail, goal: event.goal }
    case "goalCleared":
      return { ...detail, goal: undefined }
    case "queueUpdated":
      return {
        ...detail,
        promptQueue: event.queue.filter(
          (item) => !hasOptimisticUserPrompt(detail, item.text, item.attachments)
        )
      }
    case "retrying":
      return updateTurnMeta(detail, (meta) => ({ ...meta, retryStatus: event.retry }), createdAt)
    case "finished":
      return finishGenerating(
        detail,
        event.stopReason === "cancelled" || event.stopReason === "interrupted"
          ? "cancelled"
          : "completed",
        createdAt,
        { stopReason: event.stopReason, stopDetail: event.stopDetail }
      )
    case "modeChanged":
      return { ...detail, currentModeId: event.modeId }
    case "failed":
      return finishGenerating({ ...detail, streamError: event.message }, "failed", createdAt)
    case "configOptionsChanged":
      return { ...detail, configOptions: event.configOptions }
  }
}

function applyToSessionDetail(client: QueryClient, event: EventEnvelope): void {
  const key = queryKeys.session(event.subjectId)
  const detail = client.getQueryData<SessionDetailCache>(key)
  if (detail == null) return
  // Replay dedupe: the initial fetch already contains everything up to its
  // eventCursor; drop older events, then advance the cursor.
  if (event.id <= detail.eventCursor) return
  let next: SessionDetailCache = applySetupEvent({ ...detail, eventCursor: event.id }, event)
  for (const streamEvent of sessionStreamEvents(event)) {
    next = applySessionEvent(next, streamEvent, event.createdAt)
  }
  client.setQueryData(key, next)
}

function applySetupEventToMatchingSessions(client: QueryClient, event: EventEnvelope): void {
  const sessions = client.getQueriesData<SessionDetailCache>({ queryKey: ["session"] })
  for (const [key, detail] of sessions) {
    if (detail == null) continue
    const next = applySetupEvent(detail, event)
    if (next !== detail) client.setQueryData(key, next)
  }
}

export function replaySessionEvents(
  detail: SessionDetail,
  events: readonly EventEnvelope[]
): SessionDetailCache {
  const replayed = events.reduce<SessionDetailCache>(
    (current, event) => {
      let next: SessionDetailCache = applySetupEvent({ ...current, eventCursor: event.id }, event)
      for (const streamEvent of sessionStreamEvents(event)) {
        next = applySessionEvent(next, streamEvent, event.createdAt)
      }
      return next
    },
    {
      ...detail,
      conversation: [],
      eventCursor: 0
    }
  )
  return {
    ...replayed,
    // The detail cursor is the server-wide max event id used for WebSocket
    // replay de-dupe; subject history can lag that value.
    eventCursor: detail.eventCursor
  }
}

export function foldSessionSnapshot(detail: SessionDetail): SessionDetailCache {
  const turnMeta: Record<string, TurnMeta> = {}
  let assistantId: string | undefined
  let assistantMeta: TurnMeta | undefined

  const flushAssistant = () => {
    if (assistantId != null && assistantMeta != null) turnMeta[assistantId] = assistantMeta
    assistantId = undefined
    assistantMeta = undefined
  }

  for (const item of detail.conversation) {
    if (item.role !== "assistant") {
      flushAssistant()
      continue
    }
    if (assistantMeta == null) {
      assistantId = item.id
      assistantMeta = initialTurnMeta(item.createdAt)
    }
    const appended = appendTextEntry(
      assistantMeta.entries,
      assistantMeta.nextTextId,
      item.text,
      item.messageId
    )
    assistantMeta = {
      ...assistantMeta,
      entries: appended.entries,
      nextTextId: appended.nextTextId
    }
  }
  flushAssistant()

  return {
    ...detail,
    conversation: foldConversation(detail.conversation),
    turnMeta
  }
}

// Wires the event socket into the query cache. Returns the unsubscribe.
export function wireServerEvents(client: QueryClient, events: EventSocket): () => void {
  return events.subscribe((event) => {
    if (event.kind.startsWith("session.")) trackRunningSessions(event)
    switch (event.kind) {
      case "project.created":
      case "project.updated":
      case "project.deleted":
        void client.invalidateQueries({ queryKey: queryKeys.projects })
        return
      case "session.created":
      case "session.archived":
      case "session.deleted":
        void client.invalidateQueries({ queryKey: queryKeys.sessions })
        return
      case "session.updated":
        void client.invalidateQueries({ queryKey: queryKeys.sessions })
        applyToSessionDetail(client, event)
        return
      case "session.output":
      case "session.error": {
        const refreshesBranchDiff = sessionStreamEvents(event).some(
          (update) => update.type === "finished" || update.type === "failed"
        )
        applyToSessionDetail(client, event)
        if (refreshesBranchDiff) {
          void client.invalidateQueries({
            queryKey: queryKeys.sessionBranchDiff(event.subjectId)
          })
        }
        return
      }
      case "session.queue.updated":
        applyToSessionDetail(client, event)
        return
      case "worktree.setup":
        applySetupEventToMatchingSessions(client, event)
        return
      case "terminal.output":
      case "terminal.exit":
      case "update.changed":
        // Terminal frames ride their own socket; updates are out of MVP scope.
        return
    }
  })
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

export function useProjects() {
  const { client } = useApi()
  return useQuery({
    queryKey: queryKeys.projects,
    queryFn: () => client.listProjects()
  })
}

export function useSessions() {
  const { client } = useApi()
  return useQuery({
    queryKey: queryKeys.sessions,
    queryFn: () => client.listSessions()
  })
}

export function useSessionDetail(id: string | undefined) {
  const { client } = useApi()
  return useQuery({
    queryKey: queryKeys.session(id ?? ""),
    queryFn: async (): Promise<SessionDetailCache> => {
      const detail = await client.sessionDetail(id ?? "")
      const events = await client.sessionEvents(id ?? "").catch(() => [])
      if (events.length > 0) {
        return replaySessionEvents(detail, events)
      }
      // Older servers may not expose event history; fall back to the text-only
      // conversation snapshot while preserving assistant message boundaries.
      return foldSessionSnapshot(detail)
    },
    enabled: id != null && id !== ""
  })
}

export function useSessionBranchDiff(id: string | undefined) {
  const { client } = useApi()
  return useQuery<BranchDiffTotals | null>({
    queryKey: queryKeys.sessionBranchDiff(id ?? ""),
    queryFn: () => client.sessionBranchDiff(id ?? ""),
    enabled: id != null && id !== "",
    refetchInterval: 30_000
  })
}

export function useHarnesses() {
  const { client } = useApi()
  return useQuery({
    queryKey: queryKeys.harnesses,
    queryFn: () => client.listHarnesses()
  })
}

export function useCapabilities(cwd: string | undefined) {
  const { client } = useApi()
  return useQuery({
    queryKey: queryKeys.capabilities(cwd ?? ""),
    queryFn: () => client.capabilities(cwd ?? ""),
    enabled: cwd != null && cwd !== ""
  })
}

// ---------------------------------------------------------------------------
// Mutations (thin wrappers; server events confirm the results)
// ---------------------------------------------------------------------------

export function useCreateProject() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (request: CreateProjectRequest) => client.createProject(request),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: queryKeys.projects })
  })
}

// Adds a project folder, reusing (and unarchiving) an existing project
// with the same folder path — the database is shared with the macOS app, so
// "already added" is the common case, and folder_path is UNIQUE server-side.
export function useEnsureProject() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (folderPath: string) => {
      const normalized = folderPath.replace(/\/+$/, "")
      const existing = (await client.listProjects()).find(
        (project) => projectFolderPath(project)?.replace(/\/+$/, "") === normalized
      )
      if (existing != null) {
        if (existing.isArchived) {
          return client.updateProject(existing.id, { isArchived: false })
        }
        return existing
      }
      const name = normalized.split("/").at(-1) ?? normalized
      return client.createProject({ folderPath: normalized, name })
    },
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: queryKeys.projects })
  })
}

export function useUpdateProject() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, request }: { id: string; request: UpdateProjectRequest }) =>
      client.updateProject(id, request),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: queryKeys.projects })
  })
}

export function useCreateWorktree() {
  const { client } = useApi()
  return useMutation({
    mutationFn: ({ projectId, request }: { projectId: string; request: CreateWorktreeRequest }) =>
      client.createWorktree(projectId, request)
  })
}

export function useCreateSession() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (request: CreateSessionRequest) => client.createSession(request),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: queryKeys.sessions })
  })
}

export function useUpdateSession() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, request }: { id: string; request: UpdateSessionRequest }) =>
      client.updateSession(id, request),
    onSuccess: (_result, { id }) => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.sessions })
      void queryClient.invalidateQueries({ queryKey: queryKeys.session(id) })
    }
  })
}

export function usePromptSession() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({
      id,
      text,
      attachments
    }: {
      id: string
      text: string
      attachments?: readonly AttachmentRef[]
    }) => client.promptSession(id, text, attachments),
    onMutate: ({ id, text, attachments }) => {
      const key = queryKeys.session(id)
      const previous = queryClient.getQueryData<SessionDetailCache>(key)
      if (previous != null) {
        queryClient.setQueryData(key, withOptimisticUserPrompt(previous, text, attachments))
      }
      return { key, previous }
    },
    onError: (_error, _variables, context) => {
      if (context?.previous != null) {
        queryClient.setQueryData(context.key, context.previous)
      }
    }
  })
}

export function useCancelSession() {
  const { client } = useApi()
  return useMutation({
    mutationFn: (id: string) => client.cancelSession(id)
  })
}

export function useAnswerSessionQuestion() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({
      id,
      questionId,
      outcome,
      answers
    }: {
      id: string
      questionId: string
      outcome: "answered" | "cancelled"
      answers?: Record<string, QuestionAnswerEntry>
    }) => client.answerSessionQuestion(id, questionId, outcome, answers),
    onSuccess: (_result, { id }) =>
      void queryClient.invalidateQueries({ queryKey: queryKeys.session(id) })
  })
}

export function useSetSessionGoal() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({
      id,
      objective,
      status,
      tokenBudget
    }: {
      id: string
      objective?: string
      status?: GoalStatus
      tokenBudget?: number | null
    }) => client.setSessionGoal(id, { objective, status, tokenBudget }),
    onSuccess: (goal, { id }) => {
      queryClient.setQueryData<SessionDetailCache>(queryKeys.session(id), (detail) =>
        detail == null ? detail : { ...detail, goal }
      )
      void queryClient.invalidateQueries({ queryKey: queryKeys.sessions })
    }
  })
}

export function useClearSessionGoal() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => client.clearSessionGoal(id),
    onSuccess: (_result, id) => {
      queryClient.setQueryData<SessionDetailCache>(queryKeys.session(id), (detail) =>
        detail == null ? detail : { ...detail, goal: undefined }
      )
      void queryClient.invalidateQueries({ queryKey: queryKeys.sessions })
    }
  })
}

export function useSetSessionMode() {
  const { client } = useApi()
  return useMutation({
    mutationFn: ({ id, modeId }: { id: string; modeId: string }) =>
      client.setSessionMode(id, modeId)
  })
}

export function useSetSessionConfig() {
  const { client } = useApi()
  return useMutation({
    mutationFn: ({ id, configId, value }: { id: string; configId: string; value: string }) =>
      client.setSessionConfig(id, configId, value)
  })
}

export function useUpdateQueuedPrompt() {
  const { client } = useApi()
  return useMutation({
    mutationFn: ({
      sessionId,
      queueItemId,
      text
    }: {
      sessionId: string
      queueItemId: string
      text: string
    }) => client.updateQueuedPrompt(sessionId, queueItemId, text)
  })
}

export function useDeleteQueuedPrompt() {
  const { client } = useApi()
  return useMutation({
    mutationFn: ({ sessionId, queueItemId }: { sessionId: string; queueItemId: string }) =>
      client.deleteQueuedPrompt(sessionId, queueItemId)
  })
}

export function useSetHarnessEnabled() {
  const { client } = useApi()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, enabled }: { id: string; enabled: boolean }) =>
      client.setHarnessEnabled(id, enabled),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: queryKeys.harnesses })
  })
}
