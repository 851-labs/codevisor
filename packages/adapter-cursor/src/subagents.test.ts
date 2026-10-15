import * as acp from "@agentclientprotocol/sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it } from "vitest"

import { makeCursorExtension } from "./extension.js"
import { CURSOR_SUBAGENT_METHOD, CursorSubagents } from "./subagents.js"
import { payloadOf as payload } from "./test-support.js"

const SESSION = "parent"
const CHILD = "agent-1"
const FLUSH_METHOD = "_codevisor/test_flush"
const connections: Array<acp.AgentConnection> = []

afterEach(() => {
  for (const connection of connections.splice(0)) connection.close()
})

const taskCall = (
  status: acp.ToolCallStatus,
  extra: { readonly rawOutput?: unknown } = {}
): acp.SessionUpdate => {
  const call = {
    kind: "other" as const,
    rawInput: {
      _toolName: "task",
      description: "Find SQLite chat schema",
      prompt: "Find which file defines the chat tables.",
      subagentType: { unspecified: {} }
    },
    status,
    title: "Task: Find SQLite chat schema",
    toolCallId: "task-1",
    ...extra
  }
  return status === "pending"
    ? { ...call, sessionUpdate: "tool_call" }
    : { ...call, sessionUpdate: "tool_call_update" }
}

const announcement = (update: Record<string, unknown>) => ({
  sessionId: SESSION,
  update: {
    subagentSessionId: CHILD,
    _meta: { cursor: { agentId: CHILD, toolCallId: "task-1" } },
    ...update
  }
})

const cursorExtension = () => {
  const emitted: Array<RuntimeEvent> = []
  const extension = makeCursorExtension({
    emit: (event) => emitted.push(event),
    enqueueQuestion: () => new Promise(() => undefined)
  })
  const app = new acp.ClientApp().onRequest<unknown, Record<string, never>>(
    FLUSH_METHOD,
    (params) => params,
    () => ({})
  )
  const agent = new acp.AgentApp().connect(extension.configureClientApp?.(app) ?? app)
  connections.push(agent)
  const notify = (sessionId: string, update: acp.SessionUpdate) =>
    extension.mapSessionNotification?.({ sessionId, update }) ?? []
  const announce = async (params: unknown) => {
    await agent.client.notify(CURSOR_SUBAGENT_METHOD, params)
    await agent.client.request(FLUSH_METHOD, {})
  }
  return { announce, emitted, extension, notify }
}

describe("Cursor subagents", () => {
  it("shows a Task call as an agent from the start, then adds its agent from cursor/task", () => {
    const subagents = new CursorSubagents()
    const pending = subagents.mapToolUpdate(SESSION, taskCall("pending"))
    expect(pending).toMatchObject({
      kind: "agent",
      rawInput: {
        description: "Find SQLite chat schema",
        prompt: "Find which file defines the chat tables."
      },
      status: "pending",
      title: "Find SQLite chat schema"
    })
    expect(
      subagents.mapToolUpdate(SESSION, {
        rawOutput: { durationMs: 4902, isBackground: false },
        sessionUpdate: "tool_call_update",
        status: "completed",
        toolCallId: "task-1"
      })
    ).toMatchObject({ kind: "agent", status: "completed", title: "Find SQLite chat schema" })

    expect(
      payload(
        subagents.taskEvent(
          {
            agentId: "agent-1",
            durationMs: 4902,
            model: "composer-2.5-fast",
            prompt: "Find which file defines the chat tables.",
            subagentType: { custom: { explore: {} } },
            toolCallId: "task-1"
          },
          SESSION
        )
      )
    ).toEqual({
      _meta: { codevisorSubagent: { taskId: "agent-1" } },
      kind: "agent",
      rawInput: {
        description: "Find SQLite chat schema",
        prompt: "Find which file defines the chat tables.",
        subagent_type: "explore"
      },
      rawOutput: { agentId: "agent-1", durationMs: 4902, model: "composer-2.5-fast" },
      sessionUpdate: "tool_call_update",
      title: "Find SQLite chat schema",
      toolCallId: "task-1"
    })
  })

  it("leaves other tool calls alone", () => {
    const update = {
      kind: "read",
      sessionUpdate: "tool_call",
      status: "pending",
      title: "Read file",
      toolCallId: "read-1"
    }
    expect(new CursorSubagents().mapToolUpdate(SESSION, update)).toBe(update)
  })

  it("reroutes subagent announcements past the SDK's schema and nothing else", () => {
    const { extension } = cursorExtension()
    const spawned = JSON.stringify({
      jsonrpc: "2.0",
      method: "session/update",
      params: announcement({ sessionUpdate: "subagent_spawned" })
    })
    expect(JSON.parse(extension.rewriteAgentLine!(spawned))).toMatchObject({
      method: CURSOR_SUBAGENT_METHOD,
      params: { update: { sessionUpdate: "subagent_spawned" } }
    })
    const text = JSON.stringify({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: SESSION,
        update: {
          content: { text: "subagent_spawned", type: "text" },
          sessionUpdate: "agent_message_chunk"
        }
      }
    })
    expect(extension.rewriteAgentLine!(text)).toBe(text)
  })

  it("nests a subagent's own session under its agent and settles it when the session ends", async () => {
    const { announce, emitted, notify } = cursorExtension()
    notify(SESSION, taskCall("pending"))
    await announce(
      announcement({ name: "explore", sessionUpdate: "subagent_spawned", task: "Find…" })
    )
    expect(payload(emitted.at(-1))).toEqual({
      _meta: { codevisorSubagent: { taskId: CHILD } },
      sessionUpdate: "tool_call_update",
      toolCallId: "task-1"
    })

    const work = [
      ...notify(CHILD, {
        content: { text: "Find…", type: "text" },
        sessionUpdate: "user_message_chunk"
      }),
      ...notify(CHILD, {
        kind: "search",
        sessionUpdate: "tool_call",
        status: "pending",
        title: "Grep",
        toolCallId: "grep-1"
      }),
      ...notify(CHILD, {
        content: { text: "It's in schema.ts.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    ]
    expect(work.every((event) => event.subjectId === SESSION)).toBe(true)
    expect(work.map((event) => payload(event)?.parentToolCallId)).toEqual(["task-1", "task-1"])
    expect(payload(work[0])).toMatchObject({ title: "Grep", toolCallId: `${CHILD}:grep-1` })
    expect(payload(work[1])).toMatchObject({
      content: { text: "It's in schema.ts.", type: "text" },
      sessionUpdate: "agent_message_chunk"
    })

    const [returned] = notify(
      SESSION,
      taskCall("completed", { rawOutput: { durationMs: 5, isBackground: true } })
    )
    expect(payload(returned)).not.toHaveProperty("status")
    await announce(announcement({ sessionUpdate: "subagent_state_update", state: "disconnected" }))
    expect(payload(emitted.at(-1))).toEqual({
      sessionUpdate: "tool_call_update",
      status: "failed",
      toolCallId: "task-1"
    })
  })
})
