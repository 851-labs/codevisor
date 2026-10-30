import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeClaudeProvider } from "./provider.js"
import {
  definition,
  environment,
  FakeQuery,
  initMessage,
  payloadOf,
  recordsValue,
  run,
  startTestSession,
  systemMessage
} from "./test-support.js"

const startedAt = "2026-10-30T18:00:00.000Z"

describe("background tasks the SDK restates", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date(startedAt))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("keeps a background shell's spawning call when the SDK restates its tasks", async () => {
    const fake = new FakeQuery()
    const provider = makeClaudeProvider(environment, {
      checkVersion: async () => "2.1.0",
      queryFn: (input) => {
        fake.options = input.options
        return fake
      }
    })
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    fake.push(initMessage())
    await createPromise
    const latest = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map(payloadOf)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => recordsValue(payload.backgroundTasks))
        .at(-1)

    fake.push(
      systemMessage("task_started", {
        description: "npm run dev",
        task_id: "bg-9",
        task_type: "shell",
        tool_use_id: "tool-bash-9"
      })
    )
    await fake.drain()
    const started = {
      canStop: true,
      description: "npm run dev",
      id: "bg-9",
      startedAt,
      status: "running",
      taskType: "shell",
      toolUseId: "tool-bash-9"
    }
    expect(latest()).toEqual([started])

    fake.push(
      systemMessage("background_tasks_changed", {
        tasks: [{ description: "npm run dev", task_id: "bg-9", task_type: "shell" }]
      })
    )
    await fake.drain()
    expect(latest()).toEqual([started])
  })

  it("rebuilds restated tasks without hidden ones and ignores unknown notifications", async () => {
    const { fake, events } = await startTestSession()
    const snapshots = () =>
      events
        .map(payloadOf)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => recordsValue(payload.backgroundTasks))

    fake.push(systemMessage("task_started", { description: "Watch files", task_id: "bg-1" }))
    fake.push(
      systemMessage("task_started", {
        description: "Watch files",
        skip_transcript: true,
        task_id: "bg-1"
      })
    )
    await fake.drain()
    expect(snapshots().slice(1)).toEqual([
      [
        {
          canStop: true,
          description: "Watch files",
          id: "bg-1",
          startedAt,
          status: "running",
          taskType: "task"
        }
      ],
      []
    ])

    fake.push(
      systemMessage("background_tasks_changed", {
        tasks: [
          { description: "Watch files", task_id: "bg-1", task_type: "shell" },
          { description: "npm run dev", task_id: "bg-2", task_type: "shell" }
        ]
      })
    )
    fake.push(systemMessage("task_notification", { status: "completed", task_id: "bg-3" }))
    await fake.drain()

    expect(snapshots().slice(3)).toEqual([
      [
        {
          canStop: true,
          description: "npm run dev",
          id: "bg-2",
          status: "running",
          taskType: "shell"
        }
      ]
    ])
  })
})
