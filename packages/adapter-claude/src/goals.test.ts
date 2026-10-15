import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  recordValue,
  resultMessage,
  run,
  sdkMessage,
  streamEvent
} from "./test-support.js"

const commandText = (message: SDKUserMessage): string | undefined => {
  const content = message.message.content
  if (typeof content === "string") return content
  const first = content[0]
  return first?.type === "text" ? first.text : undefined
}

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("drives goal mode through /goal slash commands with synthetic snapshots", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise
    expect(created.metadata.supportsGoals).toBe(true)

    const goal = await run(created.handle.setGoal!({ objective: "ship the feature" }))
    await fake.drain()
    expect(goal.objective).toBe("ship the feature")
    expect(goal.status).toBe("active")
    const commandTexts = fake.userMessages.map(commandText)
    expect(commandTexts).toEqual(["/goal ship the feature"])
    expect(events.at(-1)?.payload).toMatchObject({ goal: { objective: "ship the feature" } })

    const paused = await run(created.handle.setGoal!({ status: "paused" }))
    await fake.drain()
    expect(paused.status).toBe("paused")
    await run(created.handle.setGoal!({ status: "active" }))
    await fake.drain()

    await run(created.handle.clearGoal!)
    await fake.drain()
    const finalTexts = fake.userMessages.map(commandText)
    expect(finalTexts).toEqual([
      "/goal ship the feature",
      "/goal pause",
      "/goal resume",
      "/goal clear"
    ])
    expect(events.at(-1)?.payload).toEqual({ goalCleared: true })

    await expect(run(created.handle.setGoal!({ status: "paused" }))).rejects.toThrow(
      "No active goal"
    )
  })

  it("settles the goal when its turn ends: success completes, interrupt pauses", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

    await run(created.handle.setGoal!({ objective: "count to ten" }))
    fake.push(streamEvent({ message: { id: "msg-goal" }, type: "message_start" }))
    fake.push(resultMessage())
    await fake.drain()
    const completed = payloadOf(
      events.findLast((event) => {
        const payload = payloadOf(event)
        return payload.goal !== undefined
      })
    )
    expect(completed.goal).toMatchObject({ objective: "count to ten", status: "complete" })
    const goalTurn = events.findLast((event) => {
      const payload = payloadOf(event)
      return payload.turnState === "ended"
    })?.payload
    expect(goalTurn).toMatchObject({ initiatedBy: "user", turnState: "ended" })

    await run(created.handle.setGoal!({ objective: "count to twenty" }))
    const cancellation = run(created.handle.cancel)
    await fake.drain()
    fake.push(resultMessage())
    await cancellation
    await fake.drain()
    const paused = payloadOf(
      events.findLast((event) => {
        const payload = payloadOf(event)
        return payload.goal !== undefined
      })
    )
    expect(paused.goal).toMatchObject({ objective: "count to twenty", status: "paused" })
  })

  it("does not settle a goal from a task-notification result", async () => {
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

    await run(created.handle.setGoal!({ objective: "ship everything" }))
    fake.push(sdkMessage({ ...resultMessage(), origin: { kind: "task-notification" } }))
    await fake.drain()
    const afterTask = payloadOf(
      events.findLast((event) => {
        const payload = payloadOf(event)
        return payload.goal !== undefined
      })
    )
    expect(recordValue(afterTask.goal).status).toBe("active")

    fake.push(resultMessage())
    await fake.drain()
    const afterGoal = payloadOf(
      events.findLast((event) => {
        const payload = payloadOf(event)
        return payload.goal !== undefined
      })
    )
    expect(recordValue(afterGoal.goal).status).toBe("complete")
  })
})
