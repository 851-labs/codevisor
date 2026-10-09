import type * as acp from "@agentclientprotocol/sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import { makeGrokBuildExtension } from "./extension.js"

const SESSION = "parent"
const CHILD = "0199c1-child"

const payload = (event: RuntimeEvent | undefined): Record<string, unknown> | undefined =>
  event?.payload as Record<string, unknown> | undefined

const taskTool = { "x.ai/tool": { kind: "task", label: "Subagent", name: "task" } }

/// Grok's Task tool call, as its ACP agent sends it.
const taskCall = (id: string, description: string, extra: Record<string, unknown> = {}) => ({
  _meta: taskTool,
  kind: "other",
  rawInput: { description, prompt: `${description}, read-only.`, subagent_type: "explore" },
  sessionUpdate: "tool_call",
  status: "pending",
  title: "task",
  toolCallId: id,
  ...extra
})

const subagentUpdate = (update: Record<string, unknown>) => ({
  sessionId: SESSION,
  update: { child_session_id: CHILD, parent_session_id: SESSION, subagent_id: CHILD, ...update }
})

/// The Grok Build extension with its notification handlers captured, as a
/// connection would drive it.
const grokExtension = () => {
  const emitted: Array<RuntimeEvent> = []
  const handlers = new Map<string, (params: unknown) => void>()
  const extension = makeGrokBuildExtension({
    emit: (event) => emitted.push(event),
    enqueueQuestion: () => new Promise(() => undefined)
  })
  const app = {
    onNotification: (
      method: string,
      _parse: unknown,
      handler: (message: { params: unknown }) => void
    ) => handlers.set(method, (params) => handler({ params })),
    onRequest: () => app
  }
  extension.configureClientApp?.(app as never)
  const notify = (sessionId: string, update: Record<string, unknown>) =>
    extension.mapSessionNotification?.({
      sessionId,
      update: update as unknown as acp.SessionNotification["update"]
    }) ?? []
  const xai = (params: unknown, method = "_x.ai/session_notification") => {
    const before = emitted.length
    handlers.get(method)?.(params)
    return emitted.slice(before)
  }
  return { notify, xai }
}

describe("Grok Build subagents", () => {
  it("shows a background subagent as an agent with its own session nested, until it finishes", () => {
    const { notify, xai } = grokExtension()
    const [pending] = notify(SESSION, taskCall("call_A", "Find auth code"))
    expect(payload(pending)).toMatchObject({
      kind: "agent",
      rawInput: {
        description: "Find auth code",
        prompt: "Find auth code, read-only.",
        subagent_type: "explore"
      },
      title: "Find auth code"
    })

    // Background is Grok's default: the call returns as soon as the subagent
    // starts, naming it; the subagent settles it later.
    const [returned] = notify(SESSION, {
      rawOutput: {
        text: `Subagent started in background.\nsubagent_id: ${CHILD}\ntype: explore`,
        type: "Text"
      },
      sessionUpdate: "tool_call_update",
      status: "completed",
      toolCallId: "call_A"
    })
    expect(payload(returned)).toMatchObject({
      _meta: { codevisorSubagent: { taskId: CHILD } },
      kind: "agent"
    })
    expect(payload(returned)).not.toHaveProperty("status")

    expect(
      xai(subagentUpdate({ description: "Find auth code", sessionUpdate: "subagent_spawned" })).map(
        payload
      )
    ).toEqual([
      {
        _meta: { codevisorSubagent: { taskId: CHILD } },
        sessionUpdate: "tool_call_update",
        toolCallId: "call_A"
      }
    ])

    const work = [
      ...notify(CHILD, {
        content: { text: "Find auth code…", type: "text" },
        sessionUpdate: "user_message_chunk"
      }),
      ...notify(CHILD, {
        kind: "search",
        sessionUpdate: "tool_call",
        status: "pending",
        title: "grep",
        toolCallId: "grep-1"
      }),
      ...notify(CHILD, {
        content: { text: "It's in auth.ts.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    ]
    expect(work.every((event) => event.subjectId === SESSION)).toBe(true)
    expect(work.map((event) => payload(event)?.parentToolCallId)).toEqual(["call_A", "call_A"])
    expect(payload(work[0])).toMatchObject({ toolCallId: `${CHILD}:grep-1` })
    expect(payload(work[1])).toMatchObject({ sessionUpdate: "agent_message_chunk" })

    // The subagent's own turn ending isn't the chat's.
    expect(
      xai({ sessionId: CHILD, update: { prompt_id: "p1", sessionUpdate: "turn_completed" } })
    ).toEqual([])

    expect(
      xai(subagentUpdate({ sessionUpdate: "subagent_finished", status: "completed" })).map(payload)
    ).toEqual([{ sessionUpdate: "tool_call_update", status: "completed", toolCallId: "call_A" }])
  })

  it("matches parallel subagents to their calls by description", () => {
    const { notify, xai } = grokExtension()
    notify(SESSION, taskCall("call_A", "Map storage"))
    notify(SESSION, taskCall("call_B", "Map paging"))
    const [linked] = xai(
      subagentUpdate({
        description: "Map paging",
        sessionUpdate: "subagent_spawned",
        subagent_type: "explore"
      })
    )
    expect(payload(linked)?.toolCallId).toBe("call_B")
  })

  it("replays a loaded session's subagents from their lifecycle updates", () => {
    const { notify, xai } = grokExtension()
    notify(SESSION, taskCall("call_A", "Find auth code"))
    const [linked] = xai(
      subagentUpdate({ description: "Find auth code", sessionUpdate: "subagent_spawned" }),
      "_x.ai/session/update"
    )
    expect(payload(linked)?.toolCallId).toBe("call_A")
  })

  it("ties a resumed subagent, and messages sent to one, to the subagent's history", () => {
    const { notify, xai } = grokExtension()
    notify(SESSION, taskCall("call_A", "Find auth code"))
    xai(subagentUpdate({ description: "Find auth code", sessionUpdate: "subagent_spawned" }))

    const [message] = notify(SESSION, {
      _meta: { "x.ai/tool": { kind: "active_agent_message", name: "send_subagent_message" } },
      kind: "other",
      rawInput: { queue: true, subagent_id: CHILD, text: "Also check the refresh path." },
      sessionUpdate: "tool_call",
      status: "pending",
      title: "Sending message to subagent",
      toolCallId: "call_M"
    })
    expect(payload(message)).toMatchObject({
      _meta: { codevisorSubagent: { taskId: CHILD } },
      kind: "other",
      rawInput: { message: "Also check the refresh path." }
    })

    notify(SESSION, taskCall("call_R", "Find auth code again"))
    const [resumed] = xai({
      sessionId: SESSION,
      update: {
        child_session_id: "0199c2-resumed",
        description: "Find auth code again",
        resumed_from: CHILD,
        sessionUpdate: "subagent_spawned",
        subagent_id: "0199c2-resumed"
      }
    })
    expect(payload(resumed)).toEqual({
      _meta: { codevisorSubagent: { continues: true, taskId: CHILD } },
      sessionUpdate: "tool_call_update",
      toolCallId: "call_R"
    })
  })

  it("leaves other tool calls alone", () => {
    const { notify } = grokExtension()
    const [read] = notify(SESSION, {
      kind: "read",
      sessionUpdate: "tool_call",
      status: "pending",
      title: "read",
      toolCallId: "read-1"
    })
    expect(payload(read)).toMatchObject({ kind: "read", title: "read" })
  })
})
