// TanStack Query layer: query keys, hooks, and the WS-driven cache
// maintenance that keeps them live. The event feed is invalidation-shaped for
// CRUD resources; session output streams are merged into the session-detail
// cache directly (no refetch per chunk), deduped against the detail's
// eventCursor exactly like the Swift client's replay handling.
import type {
  ConversationItem,
  CreateSessionRequest,
  CreateProjectRequest,
  EventEnvelope,
  SessionDetail,
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
  type CommandInfo,
  type PlanEntryInfo,
  type SessionStreamEvent,
  sessionStreamEvents,
  type ToolCallInfo,
  type UsageInfo
} from "./session-events"

export const queryKeys = {
  projects: ["projects"] as const,
  sessions: ["sessions"] as const,
  session: (id: string) => ["session", id] as const,
  harnesses: ["harnesses"] as const,
  capabilities: (cwd: string) => ["capabilities", cwd] as const
}

// Live per-assistant-turn metadata accumulated from the raw ACP stream
// (thoughts, tool calls, plan). Keyed by the conversation item id of the
// assistant message it belongs to; historical turns fetched over REST are
// text-only (the harness owns the full transcript), matching the Swift app.
export interface TurnMeta {
  startedAt: string
  thoughts: string
  toolCalls: ToolCallInfo[]
  plan?: PlanEntryInfo[]
}

// The session-detail cache: the server payload plus stream-derived fields the
// REST shape doesn't carry (a live error banner, current mode, slash
// commands, usage, and per-turn worked metadata).
export interface SessionDetailCache extends SessionDetail {
  streamError?: string
  currentModeId?: string
  availableCommands?: CommandInfo[]
  liveUsage?: UsageInfo
  turnMeta?: Record<string, TurnMeta>
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
function withGeneratingAssistant(detail: SessionDetailCache): {
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
    createdAt: isoTimestamp(),
    isGenerating: true
  }
  return { detail: { ...detail, conversation: [...detail.conversation, item] }, item }
}

function updateTurnMeta(
  detail: SessionDetailCache,
  update: (meta: TurnMeta) => TurnMeta
): SessionDetailCache {
  const { detail: withItem, item } = withGeneratingAssistant(detail)
  const current = withItem.turnMeta?.[item.id] ?? {
    startedAt: item.createdAt,
    thoughts: "",
    toolCalls: []
  }
  return {
    ...withItem,
    turnMeta: { ...withItem.turnMeta, [item.id]: update(current) }
  }
}

function appendTextChunk(
  detail: SessionDetailCache,
  chunk: Extract<SessionStreamEvent, { type: "textChunk" }>
): SessionDetailCache {
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
      createdAt: isoTimestamp(),
      isGenerating: chunk.role === "assistant"
    })
  }
  return { ...detail, conversation, streamError: undefined }
}

function upsertToolCall(
  detail: SessionDetailCache,
  call: ToolCallInfo,
  isUpdate: boolean
): SessionDetailCache {
  return updateTurnMeta(detail, (meta) => {
    const index = meta.toolCalls.findIndex((existing) => existing.toolCallId === call.toolCallId)
    if (index === -1) {
      return { ...meta, toolCalls: [...meta.toolCalls, call] }
    }
    const merged = isUpdate
      ? {
          ...meta.toolCalls[index],
          ...Object.fromEntries(Object.entries(call).filter(([, value]) => value !== undefined))
        }
      : call
    const toolCalls = [...meta.toolCalls]
    toolCalls[index] = merged as ToolCallInfo
    return { ...meta, toolCalls }
  })
}

function finishGenerating(detail: SessionDetailCache): SessionDetailCache {
  return {
    ...detail,
    conversation: detail.conversation.map((item) =>
      item.isGenerating ? { ...item, isGenerating: false } : item
    )
  }
}

function applySessionEvent(
  detail: SessionDetailCache,
  event: SessionStreamEvent
): SessionDetailCache {
  switch (event.type) {
    case "textChunk":
      return appendTextChunk(detail, event)
    case "thoughtChunk":
      return updateTurnMeta(detail, (meta) => ({
        ...meta,
        thoughts: meta.thoughts + event.text
      }))
    case "toolCall":
      return upsertToolCall(detail, event.call, false)
    case "toolCallUpdate":
      return upsertToolCall(detail, event.call, true)
    case "planUpdated":
      return updateTurnMeta(detail, (meta) => ({ ...meta, plan: event.entries }))
    case "commandsChanged":
      return { ...detail, availableCommands: event.commands }
    case "usageChanged":
      return { ...detail, liveUsage: { ...detail.liveUsage, ...event.usage } }
    case "queueUpdated":
      return { ...detail, promptQueue: [...event.queue] }
    case "finished":
      return finishGenerating(detail)
    case "modeChanged":
      return { ...detail, currentModeId: event.modeId }
    case "failed":
      return finishGenerating({ ...detail, streamError: event.message })
    case "configOptionsChanged":
      // Config metadata is read from capabilities for the MVP composer.
      return detail
  }
}

function applyToSessionDetail(client: QueryClient, event: EventEnvelope): void {
  const key = queryKeys.session(event.subjectId)
  const detail = client.getQueryData<SessionDetailCache>(key)
  if (detail == null) return
  // Replay dedupe: the initial fetch already contains everything up to its
  // eventCursor; drop older events, then advance the cursor.
  if (event.id <= detail.eventCursor) return
  let next: SessionDetailCache = { ...detail, eventCursor: event.id }
  for (const streamEvent of sessionStreamEvents(event)) {
    next = applySessionEvent(next, streamEvent)
  }
  client.setQueryData(key, next)
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
      case "session.queue.updated":
      case "session.error":
        applyToSessionDetail(client, event)
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
      // The server persists one row per streamed chunk; fold them into
      // displayable turns like the Swift client does on load.
      return { ...detail, conversation: foldConversation(detail.conversation) }
    },
    enabled: id != null && id !== ""
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
  return useMutation({
    mutationFn: ({ id, text }: { id: string; text: string }) => client.promptSession(id, text)
  })
}

export function useCancelSession() {
  const { client } = useApi()
  return useMutation({
    mutationFn: (id: string) => client.cancelSession(id)
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
