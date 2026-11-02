import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeAgentRuntime } from "./index.js"
import { INSPECTION_TIMEOUT_MS } from "./inspect-harness.js"
import { adapterSession } from "./types.js"
import type { AgentProvider, AgentSessionHandle, CreatedAgentSession } from "./types.js"

const sessionThatRecordsClose = () => {
  let closes = 0
  const closed = Promise.withResolvers<void>()
  const handle: AgentSessionHandle = {
    cancel: Effect.succeed({ runtimeState: "reusable" }),
    close: Effect.sync(() => {
      closes += 1
      closed.resolve()
    }),
    prompt: () => Effect.succeed({ stopReason: "end_turn" }),
    setConfigOption: () => Effect.succeed([]),
    setMode: () => Effect.void
  }
  const session: CreatedAgentSession = {
    handle,
    metadata: { configOptions: [], sessionId: "inspection" }
  }
  return { session, closed: closed.promise, closes: () => closes }
}

const runtimeCreating = (
  created: Promise<CreatedAgentSession>,
  stepsEntered: ReadonlyArray<string> = []
) => {
  const provider: AgentProvider = {
    id: "claude",
    readiness: () => ({ state: "ready" }),
    createSession: (_definition, _cwd, _emit, _account, _toolGateway, sessionOptions) =>
      adapterSession("createSession", () => {
        for (const step of stepsEntered) sessionOptions?.inspectionSteps?.enter(step)
        return created
      }),
    loadSession: () => Effect.die("unused")
  }
  return makeAgentRuntime({ env: { PATH: "/bin" }, providers: { claude: provider } })
}

const inspect = (runtime: ReturnType<typeof makeAgentRuntime>) =>
  Effect.runPromise(runtime.inspectHarness("claude-code", "/tmp/inspect"))

afterEach(() => {
  vi.useRealTimers()
})

describe("inspectHarness", () => {
  it("closes a session that finishes starting after the inspection timed out", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    const late = sessionThatRecordsClose()
    const starting = Promise.withResolvers<CreatedAgentSession>()
    const runtime = runtimeCreating(starting.promise)

    const inspection = inspect(runtime).then(
      () => "inspected",
      (error: unknown) => String(error)
    )
    await vi.advanceTimersByTimeAsync(INSPECTION_TIMEOUT_MS)

    expect(await inspection).toContain(`timed out after ${INSPECTION_TIMEOUT_MS}ms`)
    expect(late.closes()).toBe(0)

    starting.resolve(late.session)
    await late.closed

    expect(late.closes()).toBe(1)
  })

  it("marks a timeout and names the step the adapter was stuck in", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    const never = Promise.withResolvers<CreatedAgentSession>()
    const runtime = runtimeCreating(never.promise, ["initialize", "thread/start"])

    const inspection = inspect(runtime).then(
      () => undefined,
      (error: unknown) => error
    )
    await vi.advanceTimersByTimeAsync(INSPECTION_TIMEOUT_MS)

    expect(await inspection).toMatchObject({
      timedOut: true,
      message: expect.stringMatching(
        /^Harness inspection timed out after 15000ms \(stuck in thread\/start for \d+ms, after initialize \d+ms\)$/
      )
    })
  })

  it("closes the session once it has read the harness capabilities", async () => {
    const started = sessionThatRecordsClose()
    const runtime = runtimeCreating(Promise.resolve(started.session))

    expect(await inspect(runtime)).toMatchObject({ sessionId: "inspection" })
    await started.closed

    expect(started.closes()).toBe(1)
  })
})
