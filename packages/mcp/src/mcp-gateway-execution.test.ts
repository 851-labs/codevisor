import { createHash } from "node:crypto"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { canonicalExecutionArgs, type CodevisorExecutionState } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import {
  EXECUTION_EMIT_INTERVAL_MS,
  errorSummary,
  executionArgsHash,
  makeExecutionRecorder,
  type ExecutionTimers
} from "./mcp-gateway-execution.js"

/// A manual clock: timers fire only when the test advances time.
const manualTimers = () => {
  let now = 0
  const scheduled = new Map<number, { at: number; callback: () => void }>()
  let nextId = 0
  const timers: ExecutionTimers = {
    now: () => now,
    setTimeout: (callback, ms) => {
      nextId += 1
      scheduled.set(nextId, { at: now + ms, callback })
      return nextId
    },
    clearTimeout: (handle) => {
      scheduled.delete(handle as number)
    }
  }
  const advance = (ms: number): void => {
    now += ms
    for (const [id, timer] of scheduled) {
      if (timer.at > now) continue
      scheduled.delete(id)
      timer.callback()
    }
  }
  return { advance, scheduledCount: () => scheduled.size, timers }
}

const recording = (timers?: ExecutionTimers) => {
  const events: Array<RuntimeEvent> = []
  const recorder = makeExecutionRecorder({
    sink: (event) => {
      events.push(event)
    },
    sessionId: "session-1",
    argsHash: "hash-1",
    ...(timers === undefined ? {} : { timers })
  })
  const states = () =>
    events.map((event) => (event.payload as { execution: CodevisorExecutionState }).execution)
  return { events, recorder, states }
}

describe("execution recorder", () => {
  it("emits the start at once, throttles progress to a trailing update, and always emits the end", async () => {
    const clock = manualTimers()
    const { events, recorder, states } = recording(clock.timers)
    expect(events).toEqual([
      {
        kind: "session.output",
        subjectId: "session-1",
        payload: {
          kind: "codevisor_execution",
          argsHash: "hash-1",
          execution: { state: "running", calls: [] }
        }
      }
    ])

    recorder.status("Listing issues")
    recorder.call({ path: "linear.list_issues", ok: true, ms: 12 })
    clock.advance(EXECUTION_EMIT_INTERVAL_MS - 1)
    expect(states()).toHaveLength(1)
    clock.advance(1)
    expect(states().at(-1)).toEqual({
      state: "running",
      status: "Listing issues",
      calls: [{ path: "linear.list_issues", ok: true, ms: 12 }]
    })

    // Past the interval, the next update goes out immediately.
    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    recorder.status("   ")
    expect(states().at(-1)).toEqual({
      state: "running",
      calls: [{ path: "linear.list_issues", ok: true, ms: 12 }]
    })

    // A pending trailing update is replaced by the final state.
    recorder.call({ path: "xcode.build", machine: "MacBook", ok: false, ms: 3, error: "offline" })
    expect(clock.scheduledCount()).toBe(1)
    await recorder.finish("Script failed")
    expect(clock.scheduledCount()).toBe(0)
    expect(states().at(-1)).toEqual({
      state: "failed",
      calls: [
        { path: "linear.list_issues", ok: true, ms: 12 },
        { path: "xcode.build", machine: "MacBook", ok: false, ms: 3, error: "offline" }
      ],
      error: "Script failed"
    })

    // Stragglers after the end change nothing.
    const count = events.length
    recorder.call({ path: "late.call", ok: true, ms: 1 })
    await recorder.finish()
    expect(events).toHaveLength(count)
  })

  it("keeps the 50 most recent calls and bounds status and error text", async () => {
    const clock = manualTimers()
    const { recorder, states } = recording(clock.timers)
    for (let index = 0; index < 55; index += 1) {
      recorder.call({ path: `tool.call_${index}`, ok: true, ms: index })
    }
    recorder.call({ path: "tool.failed", ok: false, ms: 1, error: `bad ${"x".repeat(400)}` })
    recorder.status("s".repeat(300))
    await recorder.finish()

    const final = states().at(-1)!
    expect(final.state).toBe("completed")
    expect(final.calls).toHaveLength(50)
    expect(final.calls[0]?.path).toBe("tool.call_6")
    expect(final.calls.at(-1)?.error).toHaveLength(200)
    expect(final.calls.at(-1)?.error?.startsWith("bad x")).toBe(true)
    expect(final.status).toHaveLength(120)
  })

  it("never lets a failing or missing sink fail the execution", async () => {
    for (const sink of [
      async () => {
        throw new Error("sink closed")
      },
      () => {
        throw new Error("sink closed")
      }
    ]) {
      const failing = makeExecutionRecorder({ sink, sessionId: "session-1", argsHash: "hash-1" })
      failing.call({ path: "tool.one", ok: true, ms: 1 })
      await expect(failing.finish()).resolves.toBeUndefined()
    }

    const silent = makeExecutionRecorder({ sink: undefined, sessionId: "s", argsHash: "h" })
    silent.status("Working")
    await expect(silent.finish()).resolves.toBeUndefined()
  })

  it("reduces a thrown error to the message a person reads", () => {
    expect(
      errorSummary(
        "Error: codevisor.sessions.get does not accept `id`\n    at <anonymous> (codevisor-code-executor.js:45:187)",
        200
      )
    ).toBe("codevisor.sessions.get does not accept `id`")
    // Stacks flattened onto one line lose their frames too.
    expect(
      errorSummary(
        "Error: Error: boom at <anonymous> (codevisor-code-executor.js:1:2) at toError (file:///x.js:1:1)",
        200
      )
    ).toBe("boom")
    expect(errorSummary("MachineUnavailableError: MacBook Pro is offline", 200)).toBe(
      "MacBook Pro is offline"
    )
    expect(errorSummary("Error:", 200)).toBe("Error:")
    expect(errorSummary("\n  \n", 200)).toBe("")
  })

  it("hashes the canonical execute arguments as received", () => {
    const args = { description: "Build the app", code: "async () => 1" }
    expect(executionArgsHash(args)).toBe(
      createHash("sha256").update(canonicalExecutionArgs(args)).digest("hex")
    )
    expect(executionArgsHash({ code: args.code, description: args.description })).toBe(
      executionArgsHash(args)
    )
  })
})
