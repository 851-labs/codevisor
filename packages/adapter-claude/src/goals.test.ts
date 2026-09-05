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
    const commandTexts = fake.userMessages.map((message) => {
      const content = (message as { message: { content: unknown } }).message.content
      return Array.isArray(content) ? (content[0] as { text?: string }).text : content
    })
    expect(commandTexts).toEqual(["/goal ship the feature"])
    expect(events.at(-1)?.payload).toMatchObject({ goal: { objective: "ship the feature" } })

    // Pause/resume map to subcommands and update the synthetic snapshot.
    const paused = await run(created.handle.setGoal!({ status: "paused" }))
    await fake.drain()
    expect(paused.status).toBe("paused")
    await run(created.handle.setGoal!({ status: "active" }))
    await fake.drain()

    await run(created.handle.clearGoal!)
    await fake.drain()
    const finalTexts = fake.userMessages.map((message) => {
      const content = (message as { message: { content: unknown } }).message.content
      return Array.isArray(content) ? (content[0] as { text?: string }).text : content
    })
    expect(finalTexts).toEqual([
      "/goal ship the feature",
      "/goal pause",
      "/goal resume",
      "/goal clear"
    ])
    expect(events.at(-1)?.payload).toEqual({ goalCleared: true })

    // Status updates without an active goal are rejected.
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

    // The /goal turn's successful result marks the goal complete — the SDK
    // stream has no goal-state snapshots to relay.
    await run(created.handle.setGoal!({ objective: "count to ten" }))
    fake.push(streamEvent({ message: { id: "msg-goal" }, type: "message_start" }))
    fake.push(resultMessage())
    await fake.drain()
    const completed = events.findLast((event) => {
      const payload = event.payload as Record<string, unknown>
      return payload.goal !== undefined
    })?.payload as Record<string, unknown>
    expect(completed.goal).toMatchObject({ objective: "count to ten", status: "complete" })
    const goalTurn = events.findLast((event) => {
      const payload = event.payload as Record<string, unknown>
      return payload.turnState === "ended"
    })?.payload
    expect(goalTurn).toMatchObject({ initiatedBy: "user", turnState: "ended" })

    // A new goal interrupted mid-run pauses instead (resumable).
    await run(created.handle.setGoal!({ objective: "count to twenty" }))
    const cancellation = run(created.handle.cancel)
    await fake.drain()
    fake.push(resultMessage())
    await cancellation
    await fake.drain()
    const paused = events.findLast((event) => {
      const payload = event.payload as Record<string, unknown>
      return payload.goal !== undefined
    })?.payload as Record<string, unknown>
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
    fake.push({ ...resultMessage(), origin: { kind: "task-notification" } } as never)
    await fake.drain()
    const afterTask = events.findLast((event) => {
      const payload = event.payload as Record<string, unknown>
      return payload.goal !== undefined
    })?.payload as { goal: { status: string } }
    expect(afterTask.goal.status).toBe("active")

    fake.push(resultMessage())
    await fake.drain()
    const afterGoal = events.findLast((event) => {
      const payload = event.payload as Record<string, unknown>
      return payload.goal !== undefined
    })?.payload as { goal: { status: string } }
    expect(afterGoal.goal.status).toBe("complete")
  })
})
