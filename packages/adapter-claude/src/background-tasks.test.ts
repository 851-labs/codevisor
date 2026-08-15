import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { makeClaudeProvider } from "./claude.js"
import {
  definition,
  environment,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run,
  settle,
  systemMessage
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("normalizes Claude context-compaction status messages", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: RuntimeEvent[] = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(systemMessage("status", { status: "compacting" }))
    // A result wins even if a CLI version leaves the old status populated.
    fake.push(systemMessage("status", { compact_result: "success", status: "compacting" }))
    fake.push(systemMessage("status", { status: "compacting" }))
    fake.push(
      systemMessage("status", {
        compact_error: "summary failed",
        compact_result: "failed",
        status: null
      })
    )
    await settle()

    const compactions = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => payload.sessionUpdate === "context_compaction")
    expect(compactions).toEqual([
      expect.objectContaining({ sessionUpdate: "context_compaction", status: "started" }),
      expect.objectContaining({ sessionUpdate: "context_compaction", status: "completed" }),
      expect.objectContaining({ sessionUpdate: "context_compaction", status: "started" }),
      expect.objectContaining({ sessionUpdate: "context_compaction", status: "failed" })
    ])
    const firstCompactionId = compactions[0]?.compactionId
    const secondCompactionId = compactions[2]?.compactionId
    expect(firstCompactionId).toEqual(expect.any(String))
    expect(secondCompactionId).toEqual(expect.any(String))
    expect(secondCompactionId).not.toBe(firstCompactionId)
    expect(compactions.map((payload) => payload.compactionId)).toEqual([
      firstCompactionId,
      firstCompactionId,
      secondCompactionId,
      secondCompactionId
    ])
  })

  it("forwards Claude's runtime state as the quiescence barrier", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(systemMessage("session_state_changed", { state: "running" }))
    fake.push(systemMessage("session_state_changed", { state: "idle" }))
    await settle()

    const states = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => payload.runtimeState !== undefined)
    expect(states).toEqual([{ runtimeState: "running" }, { runtimeState: "idle" }])
  })

  it("surfaces Claude's internal API retry before the SDK result", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()
    fake.push(
      systemMessage("api_retry", {
        attempt: 1,
        error: "overloaded",
        error_status: 529,
        max_retries: 10,
        retry_delay_ms: 500
      })
    )
    await settle()

    expect(events.at(-1)).toMatchObject({
      kind: "session.updated",
      payload: {
        retrying: {
          attempt: 1,
          message: "Claude is overloaded, retrying",
          of: 10
        }
      }
    })
    expect(
      events.some(
        (event) =>
          event.kind === "session.updated" &&
          (event.payload as Record<string, unknown>).turnState === "ended"
      )
    ).toBe(false)

    fake.push(
      systemMessage("api_retry", {
        attempt: 2,
        error: "unknown",
        error_status: null,
        max_retries: 10,
        retry_delay_ms: 1000
      })
    )
    await settle()
    expect(events.at(-1)).toMatchObject({
      kind: "session.updated",
      payload: {
        retrying: {
          attempt: 2,
          message: "Claude connection was interrupted, retrying",
          of: 10
        }
      }
    })

    fake.push(resultMessage())
    await promptPromise
  })

  it("retitles the spawning tool call from task_started", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(
      systemMessage("task_started", {
        description: "Explore the repo",
        subagent_type: "Explore",
        task_id: "sub-1",
        tool_use_id: "toolu-agent-1"
      })
    )
    // Shell tasks must NOT be retitled as agents.
    fake.push(
      systemMessage("task_started", {
        description: "Run npm test",
        task_id: "bg-1",
        task_type: "shell",
        tool_use_id: "toolu-bash-1"
      })
    )
    await settle()

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "agent",
        sessionUpdate: "tool_call_update",
        title: "Agent: Explore the repo",
        toolCallId: "toolu-agent-1"
      })
    )
    expect(
      payloads.some(
        (payload) =>
          payload.sessionUpdate === "tool_call_update" && payload.toolCallId === "toolu-bash-1"
      )
    ).toBe(false)
  })

  it("tracks background tasks across the turn boundary and clears on notification", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    // A fresh session emits an empty snapshot so replayed clients start clean.
    const snapshots = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map((event) => event.payload as Record<string, unknown>)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
    expect(snapshots()).toContainEqual([])

    const promptPromise = run(created.handle.prompt("run tests in the background"))
    await settle()
    fake.push(
      systemMessage("task_started", {
        description: "Run npm test",
        task_id: "bg-1",
        task_type: "shell",
        tool_use_id: "tool-bash-1"
      })
    )
    fake.push(resultMessage())
    await promptPromise
    await settle()

    // The task survives turn end — that is what the waiting indicator keys on.
    const afterTurn = snapshots().at(-1)
    expect(afterTurn).toEqual([
      {
        description: "Run npm test",
        id: "bg-1",
        status: "running",
        taskType: "shell",
        toolUseId: "tool-bash-1"
      }
    ])

    fake.push(
      systemMessage("task_notification", {
        output_file: "/tmp/out.txt",
        status: "completed",
        summary: "tests passed",
        task_id: "bg-1"
      })
    )
    await settle()
    expect(snapshots().at(-1)).toEqual([])
  })

  it("rewrites background Bash through the terminal wrapper and stamps terminalKey", async () => {
    const fake = new FakeQuery()
    const provider = makeClaudeProvider(environment, {
      backgroundTerminals: {
        registry: { register: () => ({ exit: () => {}, output: () => {}, remove: () => {} }) },
        wrapCommand: (key, command) => `bg-wrap ${key} :: ${command}`
      },
      checkVersion: async () => "2.1.0",
      queryFn: (input) => {
        fake.options = input.options
        return fake as never
      }
    })
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    const sessionKey = created.metadata.sessionId

    const preToolUse = fake.options?.hooks?.PreToolUse?.[0]
    expect(preToolUse?.matcher).toBe("Bash")
    const hook = preToolUse?.hooks[0]
    expect(hook).toBeDefined()

    // Background commands are wrapped under a key derived from the tool use.
    const wrapped = await hook?.(
      {
        hook_event_name: "PreToolUse",
        tool_input: { command: "npm run dev", run_in_background: true },
        tool_name: "Bash"
      } as never,
      "tool-bash-9",
      { signal: new AbortController().signal }
    )
    expect((wrapped as { hookSpecificOutput?: unknown } | undefined)?.hookSpecificOutput).toEqual({
      hookEventName: "PreToolUse",
      updatedInput: {
        command: `bg-wrap ${sessionKey}:bg:tool-bash-9 :: npm run dev`,
        run_in_background: true
      }
    })

    // Foreground commands, malformed inputs, and hook calls without a tool
    // use id all pass through untouched.
    const foreground = await hook?.(
      {
        hook_event_name: "PreToolUse",
        tool_input: { command: "ls" },
        tool_name: "Bash"
      } as never,
      "tool-bash-10",
      { signal: new AbortController().signal }
    )
    expect(foreground).toEqual({})
    const malformed = await hook?.(
      { hook_event_name: "PreToolUse", tool_input: "ls", tool_name: "Bash" } as never,
      "tool-bash-11",
      { signal: new AbortController().signal }
    )
    expect(malformed).toEqual({})
    const anonymous = await hook?.(
      {
        hook_event_name: "PreToolUse",
        tool_input: { command: "sleep 99", run_in_background: true },
        tool_name: "Bash"
      } as never,
      undefined,
      { signal: new AbortController().signal }
    )
    expect(anonymous).toEqual({})

    // The task spawned by the wrapped tool use carries the terminal key.
    fake.push(
      systemMessage("task_started", {
        description: "npm run dev",
        task_id: "bg-9",
        task_type: "shell",
        tool_use_id: "tool-bash-9"
      })
    )
    await settle()
    const snapshots = events
      .filter((event) => event.kind === "session.updated")
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => Array.isArray(payload.backgroundTasks))
      .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
    expect(snapshots.at(-1)).toEqual([
      {
        description: "npm run dev",
        id: "bg-9",
        status: "running",
        taskType: "shell",
        terminalKey: `${sessionKey}:bg:tool-bash-9`,
        toolUseId: "tool-bash-9"
      }
    ])

    // The SDK's full level snapshot is authoritative, but carries less detail;
    // reconciliation must preserve Codevisor's terminal classification.
    fake.push(
      systemMessage("background_tasks_changed", {
        tasks: [{ description: "npm run dev", task_id: "bg-9", task_type: "shell" }]
      })
    )
    await settle()
    expect(snapshots.at(-1)?.[0]).toMatchObject({
      id: "bg-9",
      terminalKey: `${sessionKey}:bg:tool-bash-9`,
      toolUseId: "tool-bash-9"
    })

    // Task completion clears the tool-use → key mapping, so a task reusing
    // the tool use id later gets no stale terminal key.
    fake.push(systemMessage("background_tasks_changed", { tasks: [] }))
    fake.push(
      systemMessage("task_started", {
        description: "npm run dev (again)",
        task_id: "bg-10",
        task_type: "shell",
        tool_use_id: "tool-bash-9"
      })
    )
    await settle()
    const latest = events
      .filter((event) => event.kind === "session.updated")
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => Array.isArray(payload.backgroundTasks))
      .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
      .at(-1)
    expect(latest).toEqual([
      {
        description: "npm run dev (again)",
        id: "bg-10",
        status: "running",
        taskType: "shell",
        toolUseId: "tool-bash-9"
      }
    ])
  })

  it("derives subagent taskType, applies patches and hides skip_transcript tasks", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(
      systemMessage("task_started", {
        description: "Explore the codebase",
        subagent_type: "Explore",
        task_id: "sub-1"
      })
    )
    fake.push(
      systemMessage("task_started", {
        description: "Ambient housekeeping",
        skip_transcript: true,
        task_id: "ambient-1"
      })
    )
    fake.push(systemMessage("task_updated", { patch: { status: "paused" }, task_id: "sub-1" }))
    await settle()

    const snapshots = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map((event) => event.payload as Record<string, unknown>)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
    expect(snapshots().at(-1)).toEqual([
      {
        description: "Explore the codebase",
        id: "sub-1",
        status: "paused",
        taskType: "subagent"
      }
    ])
    expect(snapshots().every((snapshot) => snapshot.every((task) => task.id !== "ambient-1"))).toBe(
      true
    )

    fake.push(systemMessage("task_updated", { patch: { status: "killed" }, task_id: "sub-1" }))
    await settle()
    expect(snapshots().at(-1)).toEqual([])
  })
})
