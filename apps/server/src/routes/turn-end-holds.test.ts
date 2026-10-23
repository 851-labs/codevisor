import type { EventEnvelope } from "@codevisor/api"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { HELD_TURN_END_GRACE_MS, makeTurnEndHolds } from "./turn-end-holds.js"

const updated = (payload: Record<string, unknown>): [EventEnvelope, Record<string, unknown>] => [
  {
    id: 1,
    serverId: "server",
    kind: "session.updated",
    subjectId: "worker",
    payload,
    createdAt: "now"
  },
  payload
]

const shell = { id: "task-1", description: "npm test", status: "running", taskType: "shell" }

const heldAndDrained = (
  release: (id: string, stop: string | undefined) => Promise<void>,
  idle = () => true
) => {
  const holds = makeTurnEndHolds(release, idle)
  holds.track(...updated({ backgroundTasks: [shell] }))
  holds.track(...updated({ turnState: "ended", stopReason: "end_turn" }))
  holds.track(...updated({ backgroundTasks: [] }))
  return holds
}

describe("turn end holds", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
  })
  afterEach(() => vi.useRealTimers())

  it("keeps the hold when publishing its release fails", async () => {
    const release = vi.fn(() => Promise.reject(new Error("db busy")))
    const holds = heldAndDrained(release)

    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)

    expect(release).toHaveBeenCalledWith("worker", "end_turn")
    expect(holds.isHeld("worker")).toBe(true)
  })

  it("keeps a newer hold that arrived while the old one was being published", async () => {
    const publishing = Promise.withResolvers<void>()
    const holds = heldAndDrained(() => publishing.promise)
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)

    holds.track(...updated({ backgroundTasks: [shell] }))
    holds.track(...updated({ turnState: "ended", stopReason: "max_tokens" }))
    publishing.resolve()
    await vi.advanceTimersByTimeAsync(0)

    expect(holds.isHeld("worker")).toBe(true)
  })

  it("waits for the next turn instead of releasing while a prompt is being sent", async () => {
    const release = vi.fn(() => Promise.resolve())
    const holds = heldAndDrained(release, () => true)
    const busy = heldAndDrained(release, vi.fn().mockReturnValueOnce(true).mockReturnValue(false))

    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)

    expect(release).toHaveBeenCalledTimes(1)
    expect(holds.isHeld("worker")).toBe(false)
    expect(busy.isHeld("worker")).toBe(true)
  })
})
