import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import {
  payloadOf,
  recordsValue,
  resultMessage,
  run,
  startTestSession,
  streamEvent,
  systemMessage
} from "./test-support.js"

const startedAt = "2026-10-30T18:00:00.000Z"

describe("a background task started by the Monitor tool", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date(startedAt))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("is labeled a monitor", async () => {
    const { fake, events, created } = await startTestSession()
    const latest = () =>
      events
        .map(payloadOf)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => recordsValue(payload.backgroundTasks))
        .at(-1)

    const promptPromise = run(created.handle.prompt("watch the build"))
    await fake.nextPrompt()
    fake.push(
      streamEvent({
        content_block: { id: "tool-monitor-1", input: {}, name: "Monitor", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    fake.push(
      systemMessage("task_started", {
        description: "Watch build output",
        task_id: "bg-1",
        task_type: "local_bash",
        tool_use_id: "tool-monitor-1"
      })
    )
    fake.push(resultMessage())
    await promptPromise
    await fake.drain()

    expect(latest()).toEqual([
      {
        description: "Watch build output",
        id: "bg-1",
        startedAt,
        status: "running",
        taskType: "monitor",
        toolUseId: "tool-monitor-1"
      }
    ])
  })
})
