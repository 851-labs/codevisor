import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run,
  streamEvent
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("renders plan tools as plan updates, never as tool calls", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise
    const promptPromise = run(created.handle.prompt("plan the feature"))
    await fake.nextPrompt()

    // TodoWrite streams like any tool, but must not open a tool call.
    fake.push(streamEvent({ message: { id: "msg-plan" }, type: "message_start" }))
    fake.push(
      streamEvent({
        content_block: { id: "todo-1", name: "TodoWrite", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    await fake.drain()
    fake.push({
      message: {
        content: [
          {
            id: "todo-1",
            input: {
              todos: [
                { activeForm: "Exploring", content: "Explore the code", status: "completed" },
                { activeForm: "Designing", content: "Design the fix", status: "in_progress" },
                { activeForm: "Testing", content: "Add tests", status: "someday" },
                { content: 42, status: "pending" },
                "not-a-todo"
              ]
            },
            name: "TodoWrite",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push({
      message: {
        content: [{ content: "ok", is_error: false, tool_use_id: "todo-1", type: "tool_result" }],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)

    // ExitPlanMode carries the plan-mode plan document in input.plan.
    fake.push(
      streamEvent({
        content_block: { id: "exit-1", name: "ExitPlanMode", type: "tool_use" },
        index: 2,
        type: "content_block_start"
      })
    )
    await fake.drain()
    fake.push({
      message: {
        content: [
          {
            id: "exit-1",
            input: { plan: "# The Plan\n\n1. Do the thing\n2. Verify it" },
            name: "ExitPlanMode",
            type: "tool_use"
          },
          // Malformed plan input emits nothing (and still no tool call).
          { id: "exit-2", input: {}, name: "ExitPlanMode", type: "tool_use" }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    // No tool-call lifecycle at all for plan tools — including the turn-end
    // settle sweep (they were never registered as open).
    expect(
      payloads.filter(
        (payload) =>
          payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update"
      )
    ).toEqual([])
    const plan = payloads.find((payload) => payload.sessionUpdate === "plan")
    expect(plan?.entries).toEqual([
      { content: "Explore the code", priority: "medium", status: "completed" },
      { content: "Design the fix", priority: "medium", status: "in_progress" },
      { content: "Add tests", priority: "medium", status: "pending" }
    ])
    const documents = payloads.filter((payload) => payload.sessionUpdate === "plan_document")
    expect(documents).toEqual([
      { markdown: "# The Plan\n\n1. Do the thing\n2. Verify it", sessionUpdate: "plan_document" }
    ])
  })

  it("renders incremental Task tools as checklist snapshots outside plan mode", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    fake.push(initMessage())
    const created = await createPromise
    expect(created.metadata.modes?.currentModeId).toBe("bypassPermissions")

    const promptPromise = run(created.handle.prompt("make a checklist"))
    await fake.nextPrompt()
    fake.push(streamEvent({ message: { id: "msg-tasks" }, type: "message_start" }))
    fake.push(
      streamEvent({
        content_block: { id: "create-1", name: "TaskCreate", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    fake.push({
      message: {
        content: [
          {
            id: "create-1",
            input: {
              activeForm: "Writing tests",
              description: "Cover the task flow",
              subject: "Write tests"
            },
            name: "TaskCreate",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)

    const taskCreatedHook = fake.options?.hooks?.TaskCreated?.[0]?.hooks[0]
    expect(taskCreatedHook).toBeDefined()
    await taskCreatedHook?.(
      {
        hook_event_name: "TaskCreated",
        session_id: "sdk-session-1",
        task_description: "Cover the task flow",
        task_id: "1",
        task_subject: "Write tests"
      } as never,
      "create-1",
      { signal: new AbortController().signal }
    )
    fake.push({
      message: {
        content: [
          {
            content: "Task #1 created successfully: Write tests",
            is_error: false,
            tool_use_id: "create-1",
            type: "tool_result"
          }
        ],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)

    fake.push(
      streamEvent({
        content_block: { id: "update-1", name: "TaskUpdate", type: "tool_use" },
        index: 2,
        type: "content_block_start"
      })
    )
    fake.push({
      message: {
        content: [
          {
            id: "update-1",
            input: { status: "in_progress", taskId: "1" },
            name: "TaskUpdate",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push({
      message: {
        content: [
          {
            content: "Updated task #1 status",
            is_error: false,
            tool_use_id: "update-1",
            type: "tool_result"
          }
        ],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)
    await fake.drain()

    const taskCompletedHook = fake.options?.hooks?.TaskCompleted?.[0]?.hooks[0]
    expect(taskCompletedHook).toBeDefined()
    await taskCompletedHook?.(
      {
        hook_event_name: "TaskCompleted",
        session_id: "sdk-session-1",
        task_id: "1",
        task_subject: "Write tests"
      } as never,
      "update-2",
      { signal: new AbortController().signal }
    )
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(
      payloads.filter(
        (payload) =>
          payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update"
      )
    ).toEqual([])
    expect(payloads.filter((payload) => payload.sessionUpdate === "plan")).toEqual([
      {
        entries: [{ content: "Write tests", priority: "medium", status: "pending" }],
        sessionUpdate: "plan"
      },
      {
        entries: [{ content: "Write tests", priority: "medium", status: "in_progress" }],
        sessionUpdate: "plan"
      },
      {
        entries: [{ content: "Write tests", priority: "medium", status: "completed" }],
        sessionUpdate: "plan"
      }
    ])
  })

  it("recovers a TaskCreate id from Claude's rendered tool result", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const created = await run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    const promptPromise = run(created.handle.prompt("make a task"))
    await fake.nextPrompt()

    fake.push(
      streamEvent({
        content_block: { id: "create-fallback", name: "TaskCreate", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    fake.push({
      message: {
        content: [
          {
            id: "create-fallback",
            input: { description: "Fallback coverage", subject: "Recovered task" },
            name: "TaskCreate",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push({
      message: {
        content: [
          {
            content: "Task #42 created successfully: Recovered task",
            is_error: false,
            tool_use_id: "create-fallback",
            type: "tool_result"
          }
        ],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    expect(
      events
        .map((event) => event.payload as Record<string, unknown>)
        .find((payload) => payload.sessionUpdate === "plan")
    ).toEqual({
      entries: [{ content: "Recovered task", priority: "medium", status: "pending" }],
      sessionUpdate: "plan"
    })
  })
})
