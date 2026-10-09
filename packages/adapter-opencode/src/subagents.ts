import { runtimeEventFromNotification } from "@codevisor/adapter-acp"
import type { RuntimeEvent } from "@codevisor/agent-runtime"

type SessionNotification = Parameters<typeof runtimeEventFromNotification>[0]

/// OpenCode 2 streams a subagent's own session to clients that ask for it:
/// each update arrives as this notification, tagged with the child session.
export const CHILD_UPDATE_METHOD = "opencode/session/child_update"
/// The client capability (in `clientCapabilities._meta`) that asks for it.
export const CHILD_SESSION_UPDATES_CAPABILITY = "opencode/child-session-updates"
/// Child updates sent as plain `session/update` (a client without the
/// capability) carry the child session here.
const CHILD_SESSION_META = "opencode/child-session"

/// The updates of a subagent's own session that belong in its thread. The
/// rest (its prompt echo, plan, usage, modes) describe the child session
/// itself and would leak into the parent chat.
const CHILD_THREAD_UPDATES = new Set([
  "agent_message_chunk",
  "agent_thought_chunk",
  "tool_call",
  "tool_call_update"
])

/// The subagent tool: `subagent` in OpenCode 2, `task` in OpenCode 1 (and in
/// sessions migrated from it).
const SUBAGENT_TOOLS = new Set(["subagent", "task"])

interface AgentCall {
  readonly id: string
  /// The session whose turn made the call: the chat's, or (nested) a
  /// subagent's own.
  readonly callerSessionId: string
  description?: string
  childId?: string
  /// Resumes a subagent spawned earlier (`sessionID` in its input).
  continues: boolean
}

type JsonRecord = Record<string, unknown>

const record = (value: unknown): JsonRecord | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined

const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

/// Shows OpenCode subagents as agents: the subagent tool call becomes an
/// "agent" call titled by its task, and the subagent's own session streams
/// into it (`parentToolCallId`), the way Claude's and Codex's subagents do.
///
/// OpenCode doesn't say which call started a child session, so a new child
/// is matched to its caller's open subagent call by title (the child is
/// titled with the call's description), then confirmed by the child id the
/// call reports when it finishes.
export class OpenCodeSubagents {
  private readonly calls = new Map<string, AgentCall>()
  /// Child session id → the agent call its work streams under.
  private readonly children = new Map<string, string>()

  mapNotification(notification: SessionNotification): ReadonlyArray<RuntimeEvent> {
    const update = notification.update as unknown as JsonRecord
    const child = record(record(update._meta)?.[CHILD_SESSION_META])
    const childId = string(child?.id)
    if (child !== undefined && childId !== undefined) {
      return this.childEvents(
        notification.sessionId,
        childId,
        string(child.parentID) ?? notification.sessionId,
        string(child.title),
        update
      )
    }
    return [this.event(notification.sessionId, this.mapUpdate(notification.sessionId, update))]
  }

  /// `opencode/session/child_update`: a child session's status or one of its
  /// updates.
  childUpdate(params: unknown): ReadonlyArray<RuntimeEvent> {
    const update = record(params)
    const rootSessionId = string(update?.rootSessionId)
    const childId = string(update?.childSessionId)
    if (update === undefined || rootSessionId === undefined || childId === undefined) return []
    const parentSessionId = string(update.parentSessionId) ?? rootSessionId
    const title = string(update.title)
    if (update.type === "status") {
      return this.childStatus(rootSessionId, childId, parentSessionId, title, update.status)
    }
    const inner = record(update.update)
    return update.type === "update" && inner !== undefined
      ? this.childEvents(rootSessionId, childId, parentSessionId, title, inner)
      : []
  }

  private childStatus(
    rootSessionId: string,
    childId: string,
    parentSessionId: string,
    title: string | undefined,
    status: unknown
  ): ReadonlyArray<RuntimeEvent> {
    if (status === "created") {
      const call = this.adoptChild(childId, parentSessionId, title)
      return call === undefined ? [] : [this.event(rootSessionId, this.taskUpdate(call))]
    }
    const settled =
      status === "completed"
        ? "completed"
        : status === "failed"
          ? "failed"
          : status === "interrupted"
            ? "cancelled"
            : undefined
    const callId = this.children.get(childId)
    if (settled === undefined || callId === undefined) return []
    return [
      this.event(rootSessionId, {
        sessionUpdate: "tool_call_update",
        status: settled,
        toolCallId: callId
      })
    ]
  }

  private childEvents(
    rootSessionId: string,
    childId: string,
    parentSessionId: string,
    title: string | undefined,
    update: JsonRecord
  ): ReadonlyArray<RuntimeEvent> {
    if (!CHILD_THREAD_UPDATES.has(String(update.sessionUpdate))) return []
    const callId =
      this.children.get(childId) ?? this.adoptChild(childId, parentSessionId, title)?.id
    // Work we can't attribute is dropped rather than mixed into the chat.
    if (callId === undefined) return []
    const meta = { ...record(update._meta) }
    delete meta[CHILD_SESSION_META]
    const inner: JsonRecord = { ...update, _meta: meta }
    if (Object.keys(meta).length === 0) delete inner._meta
    // OpenCode prefixes child tool titles with the subagent's title; the
    // call already nests under it.
    const prefix = title === undefined ? undefined : `${title}: `
    const innerTitle = string(inner.title)
    if (prefix !== undefined && innerTitle?.startsWith(prefix)) {
      inner.title = innerTitle.slice(prefix.length)
    }
    return [
      this.event(rootSessionId, { ...this.mapUpdate(childId, inner), parentToolCallId: callId })
    ]
  }

  /// A subagent tool call shown as an agent; anything else unchanged.
  private mapUpdate(callerSessionId: string, update: JsonRecord): JsonRecord {
    const kind = update.sessionUpdate
    const id = string(update.toolCallId)
    if ((kind !== "tool_call" && kind !== "tool_call_update") || id === undefined) return update
    let call = this.calls.get(id)
    if (call === undefined) {
      if (!isSubagentCall(update)) return update
      call = { callerSessionId, continues: false, id }
      this.calls.set(id, call)
    }
    const mapped: JsonRecord = { ...update, kind: "agent" }

    const input = record(update.rawInput)
    if (input !== undefined && Object.keys(input).length > 0) {
      const description = string(input.description)
      if (description !== undefined) call.description = description
      const resumed = string(input.sessionID) ?? string(input.task_id)
      if (resumed !== undefined) {
        call.continues = true
        this.link(call, resumed)
      }
      const subagentType = string(input.agent) ?? string(input.subagent_type)
      mapped.rawInput = {
        ...(call.description === undefined ? {} : { description: call.description }),
        ...(string(input.prompt) === undefined ? {} : { prompt: input.prompt }),
        ...(subagentType === undefined ? {} : { subagent_type: subagentType })
      }
    } else {
      // A pending call has no input yet: leave it inputless so clients show
      // it as starting rather than as an agent named "subagent".
      delete mapped.rawInput
    }

    const metadata = record(record(update.rawOutput)?.metadata)
    const childId = string(metadata?.sessionID) ?? string(metadata?.sessionId)
    if (childId !== undefined) this.link(call, childId)
    // A background subagent's call returns while it keeps working: it
    // settles when the child session does.
    if (update.status === "completed" && metadata?.status === "running") delete mapped.status

    if (call.description !== undefined) mapped.title = call.description
    else if (string(update.title) !== undefined && SUBAGENT_TOOLS.has(String(update.title))) {
      delete mapped.title
    }
    if (call.childId !== undefined)
      mapped._meta = { ...record(update._meta), ...subagentMeta(call) }
    return mapped
  }

  /// Ties a new child session to its caller's open subagent call, preferring
  /// the one whose description titles it.
  private adoptChild(
    childId: string,
    callerSessionId: string,
    title: string | undefined
  ): AgentCall | undefined {
    const existing = this.children.get(childId)
    if (existing !== undefined) return this.calls.get(existing)
    const open = [...this.calls.values()].filter(
      (call) => call.callerSessionId === callerSessionId && call.childId === undefined
    )
    const call = open.find((candidate) => candidate.description === title) ?? open[0]
    if (call !== undefined) this.link(call, childId)
    return call
  }

  private link(call: AgentCall, childId: string): void {
    if (call.childId !== undefined && call.childId !== childId) this.children.delete(call.childId)
    call.childId = childId
    // A resumed subagent's later run streams under its newest call.
    this.children.set(childId, call.id)
  }

  private taskUpdate(call: AgentCall): JsonRecord {
    return {
      _meta: subagentMeta(call),
      sessionUpdate: "tool_call_update",
      toolCallId: call.id
    }
  }

  private event(sessionId: string, update: JsonRecord): RuntimeEvent {
    return runtimeEventFromNotification({
      sessionId,
      update: update as unknown as SessionNotification["update"]
    })
  }
}

const isSubagentCall = (update: JsonRecord): boolean => {
  const name = string(update.name)?.toLowerCase()
  if (name !== undefined) return SUBAGENT_TOOLS.has(name)
  // OpenCode 1 sends no tool name: its subagent call is the "think" call
  // titled with the tool's name.
  return update.kind === "think" && SUBAGENT_TOOLS.has(String(update.title).toLowerCase())
}

/// Ties every call of one subagent together (its child session), so opening
/// any of them shows its whole history.
const subagentMeta = (call: AgentCall): JsonRecord => ({
  codevisorSubagent: {
    taskId: call.childId,
    ...(call.continues ? { continues: true } : {})
  }
})
