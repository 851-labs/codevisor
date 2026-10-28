import type { EventEnvelope } from "@codevisor/api"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import {
  HELD_TURN_END_ATTEMPTS,
  HELD_TURN_END_GRACE_MS,
  makeTurnEndHolds,
  type ReleaseTurnEnd
} from "./turn-end-holds.js"

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

const heldAndDrained = (release: ReleaseTurnEnd, idle: () => boolean = () => true) => {
  const holds = makeTurnEndHolds(release, idle, new Set())
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

  it("retries a release whose publication failed until it goes out", async () => {
    const release = vi
      .fn<ReleaseTurnEnd>()
      .mockRejectedValueOnce(new Error("db busy"))
      .mockResolvedValue(undefined)
    const holds = heldAndDrained(release)

    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)
    expect(release).toHaveBeenCalledTimes(1)
    expect(holds.isHeld("worker")).toBe(true)

    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)
    expect(release).toHaveBeenCalledTimes(2)
    expect(release).toHaveBeenLastCalledWith("worker", "end_turn", expect.any(Function))
    expect(holds.isHeld("worker")).toBe(false)
  })

  it("stops retrying after a bounded number of attempts", async () => {
    const release = vi.fn<ReleaseTurnEnd>().mockRejectedValue(new Error("db gone"))
    heldAndDrained(release)

    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS * (HELD_TURN_END_ATTEMPTS + 2))

    expect(release).toHaveBeenCalledTimes(HELD_TURN_END_ATTEMPTS)
  })

  it("marks an in-flight release stale once the agent moves on", async () => {
    const publishing = Promise.withResolvers<void>()
    let stale: (() => boolean) | undefined
    const holds = heldAndDrained((_id, _stop, isStale) => {
      stale = isStale
      return publishing.promise
    })
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)
    expect(stale?.()).toBe(false)

    holds.track(...updated({ turnState: "started", turnId: "turn-2" }))
    publishing.resolve()
    await vi.advanceTimersByTimeAsync(0)

    expect(stale?.()).toBe(true)
    expect(holds.isHeld("worker")).toBe(true)
  })

  it("doesn't retry a failed release the agent has moved past", async () => {
    const failing = Promise.withResolvers<void>()
    const release = vi.fn<ReleaseTurnEnd>().mockReturnValueOnce(failing.promise)
    const holds = heldAndDrained(release)
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)

    holds.track(...updated({ turnState: "ended", stopReason: "end_turn" }))
    failing.reject(new Error("db busy"))
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS * 2)

    expect(release).toHaveBeenCalledTimes(1)
    expect(holds.isHeld("worker")).toBe(false)
  })

  it("waits for the next turn instead of releasing while a prompt is being sent", async () => {
    const release = vi.fn<ReleaseTurnEnd>().mockResolvedValue(undefined)
    const holds = heldAndDrained(release, () => true)
    const busy = heldAndDrained(release, vi.fn().mockReturnValueOnce(true).mockReturnValue(false))

    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)

    expect(release).toHaveBeenCalledTimes(1)
    expect(holds.isHeld("worker")).toBe(false)
    expect(busy.isHeld("worker")).toBe(true)
  })
})
