import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  recordsValue,
  resultMessage,
  run,
  startTestSession,
  systemMessage
} from "./test-support.js"

const startedAt = "2026-10-30T18:00:00.000Z"

describe("ClaudeProvider", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date(startedAt))
  })

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
    fake.push(initMessage())
    await createPromise

    fake.push(systemMessage("status", { status: "compacting" }))
    fake.push(systemMessage("status", { compact_result: "success", status: "compacting" }))
    fake.push(systemMessage("status", { status: "compacting" }))
    fake.push(
      systemMessage("status", {
        compact_error: "summary failed",
        compact_result: "failed",
        status: null
      })
    )
    await fake.drain()

    const compactions = events
      .map(payloadOf)
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
    fake.push(initMessage())
    await createPromise

    fake.push(systemMessage("session_state_changed", { state: "running" }))
    fake.push(systemMessage("session_state_changed", { state: "idle" }))
    await fake.drain()

    const states = events.map(payloadOf).filter((payload) => payload.runtimeState !== undefined)
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
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    fake.push(
      systemMessage("api_retry", {
        attempt: 1,
        error: "overloaded",
        error_status: 529,
        max_retries: 10,
        retry_delay_ms: 500
      })
    )
    await fake.drain()

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
        (event) => event.kind === "session.updated" && payloadOf(event).turnState === "ended"
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
    await fake.drain()
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
    fake.push(
      systemMessage("task_started", {
        description: "Run npm test",
        task_id: "bg-1",
        task_type: "shell",
        tool_use_id: "toolu-bash-1"
      })
    )
    await fake.drain()

    const payloads = events.map(payloadOf)
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
    const { fake, events, created } = await startTestSession()

    const snapshots = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map(payloadOf)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => recordsValue(payload.backgroundTasks))
    expect(snapshots()).toContainEqual([])

    const promptPromise = run(created.handle.prompt("run tests in the background"))
    await fake.nextPrompt()
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
    await fake.drain()

    const afterTurn = snapshots().at(-1)
    expect(afterTurn).toEqual([
      {
        canStop: true,
        description: "Run npm test",
        id: "bg-1",
        startedAt,
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
    await fake.drain()
    expect(snapshots().at(-1)).toEqual([])
  })

  it("derives subagent taskType, applies patches and hides skip_transcript tasks", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
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
    await fake.drain()

    const snapshots = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map(payloadOf)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => recordsValue(payload.backgroundTasks))
    expect(snapshots().at(-1)).toEqual([
      {
        canStop: true,
        description: "Explore the codebase",
        id: "sub-1",
        startedAt,
        status: "paused",
        taskType: "subagent"
      }
    ])
    expect(snapshots().every((snapshot) => snapshot.every((task) => task.id !== "ambient-1"))).toBe(
      true
    )

    fake.push(systemMessage("task_updated", { patch: { status: "killed" }, task_id: "sub-1" }))
    await fake.drain()
    expect(snapshots().at(-1)).toEqual([])
  })

  it("renames a background task from progress summaries and description patches", async () => {
    const { fake, events } = await startTestSession()
    const snapshots = () =>
      events
        .map(payloadOf)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => recordsValue(payload.backgroundTasks))

    fake.push(
      systemMessage("task_started", {
        description: "Run npm test",
        task_id: "bg-1",
        task_type: "shell",
        tool_use_id: "tool-bash-1"
      })
    )
    fake.push(systemMessage("task_progress", { summary: "Running 40 suites", task_id: "bg-1" }))
    fake.push(systemMessage("task_progress", { summary: "Running 40 suites", task_id: "bg-1" }))
    fake.push(systemMessage("task_progress", { task_id: "bg-1" }))
    fake.push(systemMessage("task_progress", { summary: "Unknown work", task_id: "bg-2" }))
    await fake.drain()

    expect(snapshots()).toHaveLength(3)
    expect(
      snapshots()
        .at(-1)
        ?.map((task) => task.description)
    ).toEqual(["Running 40 suites"])

    fake.push(systemMessage("task_updated", { patch: { description: "Tests" }, task_id: "bg-1" }))
    fake.push(systemMessage("task_updated", { patch: { status: "completed" }, task_id: "bg-2" }))
    await fake.drain()

    expect(snapshots()).toHaveLength(4)
    expect(snapshots().at(-1)).toEqual([
      {
        canStop: true,
        description: "Tests",
        id: "bg-1",
        startedAt,
        status: "running",
        taskType: "shell",
        toolUseId: "tool-bash-1"
      }
    ])
  })

  it("words rate-limit and server-error retries, and stays quiet outside a turn", async () => {
    const { fake, events, created } = await startTestSession()
    const retries = () =>
      events
        .map(payloadOf)
        .flatMap((payload) => (payload.retrying === undefined ? [] : [payload.retrying]))

    fake.push(
      systemMessage("api_retry", {
        attempt: 1,
        error: "overloaded",
        error_status: 529,
        max_retries: 10,
        retry_delay_ms: 500
      })
    )
    fake.push(systemMessage("status", { status: null }))
    await fake.drain()
    expect(retries()).toEqual([])

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    fake.push(
      systemMessage("api_retry", {
        attempt: 0,
        error: "unknown",
        error_status: 429,
        max_retries: 0,
        retry_delay_ms: 500
      })
    )
    fake.push(
      systemMessage("api_retry", {
        attempt: 2,
        error: "unknown",
        error_status: 503,
        max_retries: 10,
        retry_delay_ms: 500
      })
    )
    fake.push(resultMessage())
    await promptPromise

    expect(retries()).toEqual([
      { message: "Claude is temporarily rate limited, retrying" },
      { attempt: 2, message: "Claude returned a server error, retrying", of: 10 }
    ])
    expect(
      events.map(payloadOf).some((payload) => payload.sessionUpdate === "context_compaction")
    ).toBe(false)
  })
})
