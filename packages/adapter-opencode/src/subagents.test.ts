import { describe, expect, it } from "vitest"

import { OpenCodeSubagents } from "./subagents.js"

const ROOT = "ses_root"

const notification = (update: Record<string, unknown>) =>
  ({ sessionId: ROOT, update }) as unknown as Parameters<OpenCodeSubagents["mapNotification"]>[0]

const payloads = (events: ReadonlyArray<{ payload: unknown }>) =>
  events.map((event) => event.payload as Record<string, unknown>)

const subagentCall = (status: string, extra: Record<string, unknown> = {}) =>
  notification({
    kind: "think",
    name: "subagent",
    sessionUpdate: status === "pending" ? "tool_call" : "tool_call_update",
    status,
    title: "subagent",
    toolCallId: "call_A",
    ...extra
  })

const childUpdate = (childId: string, title: string, event: Record<string, unknown>) => ({
  childSessionId: childId,
  depth: 1,
  parentSessionId: ROOT,
  rootSessionId: ROOT,
  title,
  ...event
})

const input = {
  agent: "explore",
  description: "Find auth code",
  prompt: "Find where auth tokens are checked."
}

describe("OpenCode subagents", () => {
  it("shows a subagent as an agent with its own session nested under it", () => {
    const subagents = new OpenCodeSubagents()
    // Pending: no input yet, so it stays inputless (a client shows it starting).
    const [pending] = payloads(subagents.mapNotification(subagentCall("pending", { rawInput: {} })))
    expect(pending).toMatchObject({ kind: "agent", toolCallId: "call_A" })
    expect(pending).not.toHaveProperty("rawInput")
    expect(pending).not.toHaveProperty("title")

    const [running] = payloads(
      subagents.mapNotification(subagentCall("in_progress", { rawInput: input }))
    )
    expect(running).toMatchObject({
      kind: "agent",
      rawInput: {
        description: "Find auth code",
        prompt: "Find where auth tokens are checked.",
        subagent_type: "explore"
      },
      status: "in_progress",
      title: "Find auth code"
    })

    const created = payloads(
      subagents.childUpdate(
        childUpdate("ses_child", "Find auth code", { status: "created", type: "status" })
      )
    )
    expect(created).toEqual([
      {
        _meta: { codevisorSubagent: { taskId: "ses_child" } },
        sessionUpdate: "tool_call_update",
        toolCallId: "call_A"
      }
    ])

    const work = [
      {
        content: { text: "Looking.", type: "text" },
        messageId: "m1",
        sessionUpdate: "agent_message_chunk"
      },
      {
        kind: "read",
        name: "read",
        sessionUpdate: "tool_call",
        status: "pending",
        title: "Find auth code: read",
        toolCallId: "ses_child:call_x"
      },
      // The child's own prompt echo and plan describe its session, not its work.
      { content: { text: "Find where…", type: "text" }, sessionUpdate: "user_message_chunk" },
      { entries: [], sessionUpdate: "plan" }
    ].flatMap((update) =>
      subagents.childUpdate(
        childUpdate("ses_child", "Find auth code", {
          type: "update",
          update: {
            ...update,
            _meta: { "opencode/child-session": { depth: 1, id: "ses_child", parentID: ROOT } }
          }
        })
      )
    )
    expect(work.map((event) => event.subjectId)).toEqual([ROOT, ROOT])
    expect(payloads(work)).toEqual([
      {
        content: { text: "Looking.", type: "text" },
        messageId: "m1",
        parentToolCallId: "call_A",
        sessionUpdate: "agent_message_chunk"
      },
      {
        kind: "read",
        name: "read",
        parentToolCallId: "call_A",
        sessionUpdate: "tool_call",
        status: "pending",
        title: "read",
        toolCallId: "ses_child:call_x"
      }
    ])

    // The completion carries no tool name; the call is still the agent.
    const [completed] = payloads(
      subagents.mapNotification(
        subagentCall("completed", {
          kind: undefined,
          name: undefined,
          rawOutput: { metadata: { sessionID: "ses_child", status: "completed" } },
          title: undefined
        })
      )
    )
    expect(completed).toMatchObject({
      _meta: { codevisorSubagent: { taskId: "ses_child" } },
      kind: "agent",
      status: "completed",
      title: "Find auth code"
    })
  })

  it("keeps a background subagent running until its session finishes", () => {
    const subagents = new OpenCodeSubagents()
    subagents.mapNotification(subagentCall("in_progress", { rawInput: input }))
    subagents.childUpdate(
      childUpdate("ses_child", "Find auth code", { status: "created", type: "status" })
    )

    const [returned] = payloads(
      subagents.mapNotification(
        subagentCall("completed", {
          rawOutput: { metadata: { sessionID: "ses_child", status: "running" } }
        })
      )
    )
    expect(returned).not.toHaveProperty("status")

    expect(
      payloads(
        subagents.childUpdate(
          childUpdate("ses_child", "Find auth code", { status: "completed", type: "status" })
        )
      )
    ).toEqual([{ sessionUpdate: "tool_call_update", status: "completed", toolCallId: "call_A" }])
    expect(
      payloads(
        subagents.childUpdate(
          childUpdate("ses_child", "Find auth code", { status: "interrupted", type: "status" })
        )
      )
    ).toEqual([{ sessionUpdate: "tool_call_update", status: "cancelled", toolCallId: "call_A" }])
  })

  it("matches parallel subagents to their calls by title", () => {
    const subagents = new OpenCodeSubagents()
    for (const [id, description] of [
      ["call_A", "Map storage"],
      ["call_B", "Map paging"]
    ] as const) {
      subagents.mapNotification(
        notification({
          name: "subagent",
          rawInput: { agent: "explore", description, prompt: "…" },
          sessionUpdate: "tool_call_update",
          status: "in_progress",
          toolCallId: id
        })
      )
    }
    subagents.childUpdate(
      childUpdate("ses_paging", "Map paging", { status: "created", type: "status" })
    )
    subagents.childUpdate(
      childUpdate("ses_storage", "Map storage", { status: "created", type: "status" })
    )

    const [paging] = payloads(
      subagents.childUpdate(
        childUpdate("ses_paging", "Map paging", {
          type: "update",
          update: { content: { text: "…", type: "text" }, sessionUpdate: "agent_message_chunk" }
        })
      )
    )
    expect(paging?.parentToolCallId).toBe("call_B")
  })

  it("nests child updates that arrive as plain session updates, and drops ones it can't attribute", () => {
    const subagents = new OpenCodeSubagents()
    subagents.mapNotification(subagentCall("in_progress", { rawInput: input }))
    const childMeta = {
      "opencode/child-session": {
        depth: 1,
        id: "ses_child",
        parentID: ROOT,
        title: "Find auth code"
      }
    }

    const [nested] = payloads(
      subagents.mapNotification(
        notification({
          _meta: childMeta,
          content: { text: "Found it.", type: "text" },
          sessionUpdate: "agent_message_chunk"
        })
      )
    )
    expect(nested).toEqual({
      content: { text: "Found it.", type: "text" },
      parentToolCallId: "call_A",
      sessionUpdate: "agent_message_chunk"
    })

    const stray = new OpenCodeSubagents().mapNotification(
      notification({
        _meta: childMeta,
        content: { text: "Found it.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(stray).toEqual([])
  })

  it("ties a resumed subagent to the agent it continues", () => {
    const subagents = new OpenCodeSubagents()
    const [resumed] = payloads(
      subagents.mapNotification(
        subagentCall("in_progress", { rawInput: { ...input, sessionID: "ses_child" } })
      )
    )
    expect(resumed).toMatchObject({
      _meta: { codevisorSubagent: { continues: true, taskId: "ses_child" } },
      kind: "agent"
    })
  })

  it("leaves other tool calls alone", () => {
    const update = {
      kind: "read",
      name: "read",
      sessionUpdate: "tool_call",
      status: "pending",
      title: "read",
      toolCallId: "call_read"
    }
    expect(payloads(new OpenCodeSubagents().mapNotification(notification(update)))).toEqual([
      update
    ])
  })
})
