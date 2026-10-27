import { afterEach, describe, expect, it, vi } from "vitest"

import { isoTime, systemClock } from "./clock.js"

describe("systemClock", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("repeats a task every interval until cancelled", () => {
    vi.useFakeTimers({ now: Date.parse("2026-10-27T12:00:00.000Z") })
    const task = vi.fn()
    const cancel = systemClock.every(1_000, task)

    vi.advanceTimersByTime(999)
    expect(task).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1_001)
    expect(task).toHaveBeenCalledTimes(2)

    cancel()
    vi.advanceTimersByTime(5_000)
    expect(task).toHaveBeenCalledTimes(2)
    expect(isoTime(systemClock.now())).toBe("2026-10-27T12:00:07.000Z")
  })
})
