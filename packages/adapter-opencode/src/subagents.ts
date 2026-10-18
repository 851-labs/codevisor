import { runtimeEventFromNotification, type AcpUpdateNotification } from "@codevisor/adapter-acp"
import type { RuntimeEvent } from "@codevisor/agent-runtime"

import { record, type JsonRecord } from "./internal.js"

export const CHILD_UPDATE_METHOD = "opencode/session/child_update"
export const CHILD_SESSION_UPDATES_CAPABILITY = "opencode/child-session-updates"
const CHILD_SESSION_META = "opencode/child-session"

const CHILD_THREAD_UPDATES = new Set([
  "agent_message_chunk",
  "agent_thought_chunk",
  "tool_call",
  "tool_call_update"
])

const SUBAGENT_TOOLS = new Set(["subagent", "task"])

interface AgentCall {
  readonly id: string
  readonly callerSessionId: string
  description?: string
  childId?: string
  continues: boolean
}

const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

export class OpenCodeSubagents {
  private readonly calls = new Map<string, AgentCall>()
  private readonly children = new Map<string, string>()

  mapNotification(notification: AcpUpdateNotification): ReadonlyArray<RuntimeEvent> {
    const { update } = notification
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
    if (update.type !== "update" || inner === undefined) return []
    return this.childEvents(rootSessionId, childId, parentSessionId, title, inner)
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
    const settled = childTerminalStatus(status)
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
    if (callId === undefined) return []
    const inner = childThreadUpdate(update, title)
    return [
      this.event(rootSessionId, { ...this.mapUpdate(childId, inner), parentToolCallId: callId })
    ]
  }

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

    this.mapCallInput(call, update, mapped)
    this.mapCallResult(call, update, mapped)
    this.mapCallPresentation(call, update, mapped)
    return mapped
  }

  private mapCallInput(call: AgentCall, update: JsonRecord, mapped: JsonRecord): void {
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
      delete mapped.rawInput
    }
  }

  private mapCallResult(call: AgentCall, update: JsonRecord, mapped: JsonRecord): void {
    const metadata = record(record(update.rawOutput)?.metadata)
    const childId = string(metadata?.sessionID) ?? string(metadata?.sessionId)
    if (childId !== undefined) this.link(call, childId)
    if (update.status === "completed" && metadata?.status === "running") delete mapped.status
  }

  private mapCallPresentation(call: AgentCall, update: JsonRecord, mapped: JsonRecord): void {
    if (call.description !== undefined) mapped.title = call.description
    else if (string(update.title) !== undefined && SUBAGENT_TOOLS.has(String(update.title))) {
      delete mapped.title
    }
    if (call.childId !== undefined)
      mapped._meta = { ...record(update._meta), ...subagentMeta(call) }
  }

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
    return runtimeEventFromNotification({ sessionId, update })
  }
}

const childTerminalStatus = (status: unknown): string | undefined => {
  switch (status) {
    case "completed":
      return "completed"
    case "failed":
      return "failed"
    case "interrupted":
      return "cancelled"
    default:
      return undefined
  }
}

const childThreadUpdate = (update: JsonRecord, title: string | undefined): JsonRecord => {
  const meta = { ...record(update._meta) }
  delete meta[CHILD_SESSION_META]
  const inner: JsonRecord = { ...update, _meta: meta }
  if (Object.keys(meta).length === 0) delete inner._meta
  const prefix = title === undefined ? undefined : `${title}: `
  const innerTitle = string(inner.title)
  if (prefix !== undefined && innerTitle?.startsWith(prefix)) {
    inner.title = innerTitle.slice(prefix.length)
  }
  return inner
}

const isSubagentCall = (update: JsonRecord): boolean => {
  const name = string(update.name)?.toLowerCase()
  if (name !== undefined) return SUBAGENT_TOOLS.has(name)
  return update.kind === "think" && SUBAGENT_TOOLS.has(String(update.title).toLowerCase())
}

const subagentMeta = (call: AgentCall): JsonRecord => ({
  codevisorSubagent: {
    taskId: call.childId,
    ...(call.continues ? { continues: true } : {})
  }
})
