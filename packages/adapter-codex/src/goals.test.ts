import { describe, expect, it } from "vitest"
import { run, setup } from "./test-support.js"

describe("CodexProvider", () => {
  it("advertises goal support and sets goals with double-option budget semantics", async () => {
    const { client, created, events } = await setup()
    expect(created?.metadata.supportsGoals).toBe(true)

    // Omitted budget key stays omitted on the wire (keep semantics).
    const goal = await run(created!.handle.setGoal!({ objective: "ship goal mode" }))
    let request = client.requests.findLast((entry) => entry.method === "thread/goal/set")
    expect(request?.params).toEqual({ objective: "ship goal mode", threadId: "thread-new" })
    expect(goal.objective).toBe("ship goal mode")
    expect(goal.status).toBe("active")
    expect(goal.createdAt).toBe(new Date(1_700_000_000 * 1000).toISOString())
    expect(events.at(-1)?.payload).toEqual({ goal })

    // A number sets the budget; pause is just a status update.
    await run(created!.handle.setGoal!({ status: "paused", tokenBudget: 50_000 }))
    request = client.requests.findLast((entry) => entry.method === "thread/goal/set")
    expect(request?.params).toEqual({
      status: "paused",
      threadId: "thread-new",
      tokenBudget: 50_000
    })

    // Explicit null clears the budget (double-option), keeping the objective.
    const cleared = await run(created!.handle.setGoal!({ tokenBudget: null }))
    request = client.requests.findLast((entry) => entry.method === "thread/goal/set")
    expect(request?.params).toEqual({ threadId: "thread-new", tokenBudget: null })
    expect(cleared.objective).toBe("ship goal mode")
    expect(cleared.tokenBudget).toBeNull()
  })

  it("clears goals and forwards agent-side cleared notifications", async () => {
    const { client, created, events } = await setup()
    await run(created!.handle.setGoal!({ objective: "tidy up" }))
    await run(created!.handle.clearGoal!)
    expect(client.requests.at(-1)).toMatchObject({
      method: "thread/goal/clear",
      params: { threadId: "thread-new" }
    })
    expect(events.at(-1)?.payload).toEqual({ goalCleared: true })

    client.emit("thread/goal/cleared", { threadId: "thread-new" })
    await Promise.resolve()
    expect(events.at(-1)?.payload).toEqual({ goalCleared: true })
  })

  it("emits out-of-band goal snapshots immediately and throttles accounting ticks", async () => {
    const { client, events } = await setup()
    const snapshot = (overrides: Record<string, unknown>) => ({
      createdAt: 1_700_000_000,
      objective: "long haul",
      status: "active",
      threadId: "thread-new",
      timeUsedSeconds: 1,
      tokenBudget: 10_000,
      tokensUsed: 100,
      updatedAt: 1_700_000_001,
      ...overrides
    })

    // Out-of-band snapshot (turnId null — e.g. resume) always emits.
    client.emit("thread/goal/updated", { goal: snapshot({}), threadId: "thread-new", turnId: null })
    expect(events.at(-1)?.payload).toMatchObject({ goal: { objective: "long haul" } })
    const countAfterSnapshot = events.length

    // Accounting-only tick inside a turn within the rate window is held back.
    client.emit("thread/goal/updated", {
      goal: snapshot({ tokensUsed: 200 }),
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.length).toBe(countAfterSnapshot)

    // A material change (status flip) bypasses the throttle.
    client.emit("thread/goal/updated", {
      goal: snapshot({ status: "budgetLimited", tokensUsed: 10_000 }),
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.at(-1)?.payload).toMatchObject({
      goal: { status: "budgetLimited", tokensUsed: 10_000 }
    })

    // Malformed goals are skipped, not thrown.
    client.emit("thread/goal/updated", {
      goal: snapshot({ status: "later" }),
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("thread/goal/updated", { goal: "nope", threadId: "thread-new", turnId: "turn-1" })
    expect(events.at(-1)?.payload).toMatchObject({ goal: { status: "budgetLimited" } })
  })

  it("flushes held accounting snapshots before the turn-ended event", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("work"))
    await Promise.resolve()
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-1" } })
    const goal = {
      createdAt: 1_700_000_000,
      objective: "long haul",
      status: "active",
      threadId: "thread-new",
      timeUsedSeconds: 1,
      tokenBudget: null,
      tokensUsed: 50,
      updatedAt: 1_700_000_001
    }
    // First in-turn update emits (it materially differs from "no goal")…
    client.emit("thread/goal/updated", { goal, threadId: "thread-new", turnId: "turn-1" })
    // …then a same-shape accounting tick is held by the rate limit.
    client.emit("thread/goal/updated", {
      goal: { ...goal, tokensUsed: 999 },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const heldCount = events.length
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "completed" }
    })
    await promptPromise
    expect(events.length).toBeGreaterThan(heldCount)
    const goalFlush = events.at(-2)
    const turnEnded = events.at(-1)
    expect(goalFlush?.payload).toMatchObject({ goal: { tokensUsed: 999 } })
    expect(turnEnded?.payload).toMatchObject({ turnState: "ended" })
  })
})
