import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import {
  PATH,
  ROOT,
  delivered,
  isPrompt,
  run,
  setup,
  terminal,
  text,
  turnStates
} from "./session-test-support.js"
import { event, payload } from "./test-support.js"

const failing = async (error: Record<string, unknown>) => {
  const s = setup()
  const turn = run(Effect.result(s.handle.prompt("go")))
  await s.requested(isPrompt("msg_1"))
  s.queue.push(
    delivered("msg_1"),
    event("session.step.failed", { sessionID: ROOT, error }),
    event("session.execution.failed", { sessionID: ROOT, error })
  )
  const result = await turn
  return { result, ended: s.events.map(payload).filter((entry) => entry.turnState === "ended") }
}

describe("OpenCode server session turns", () => {
  it("runs a turn from the delivered prompt to the end of its execution", async () => {
    const s = setup()
    expect(s.metadata.configOptions.map((option) => option.currentValue)).toEqual([
      "openrouter/m1",
      "default"
    ])
    expect(s.metadata.modes).toEqual({
      currentModeId: "build",
      availableModes: [
        { id: "build", name: "Build" },
        { id: "plan", name: "Plan", canonicalId: "plan" }
      ]
    })
    const turn = run(s.handle.prompt("hello"))
    const submitted = await s.requested(isPrompt("msg_1"))
    expect(submitted.body).toEqual({ text: "hello", id: "msg_1", delivery: "steer" })
    s.queue.push(
      text("stale output from an earlier execution"),
      delivered("msg_1"),
      text("Hi"),
      event("session.step.ended", {
        sessionID: ROOT,
        finish: "stop",
        tokens: { input: 10, output: 5, reasoning: 0, cache: { read: 3, write: 0 } }
      }),
      terminal("succeeded")
    )
    await expect(turn).resolves.toEqual({ stopReason: "end_turn" })
    expect(s.updates("agent_message_chunk").map((update) => update.content)).toEqual([
      { type: "text", text: "Hi" }
    ])
    expect(s.updates("usage_update")).toEqual([
      {
        sessionUpdate: "usage_update",
        used: 18,
        size: 1000,
        cost: { amount: 0.25, currency: "USD" }
      }
    ])
    expect(turnStates(s.events)).toEqual(["started", "ended"])
  })

  it("lands a steer in the running turn and declines one when nothing is running", async () => {
    const s = setup()
    await expect(run(s.handle.steer!("too early"))).resolves.toBe(false)
    const turn = run(s.handle.prompt("first"))
    await s.requested(isPrompt("msg_1"))
    s.queue.push(delivered("msg_1"))
    await expect(run(s.handle.steer!("also this"))).resolves.toBe(true)
    expect((await s.requested(isPrompt("msg_2"))).body).toEqual({
      text: "also this",
      id: "msg_2",
      delivery: "steer",
      resume: false
    })
    s.queue.push(delivered("msg_2"), text("steered"), terminal("succeeded"))
    await expect(turn).resolves.toEqual({ stopReason: "end_turn" })
    expect(turnStates(s.events)).toEqual(["started", "ended"])
    await expect(run(s.handle.steer!("too late"))).resolves.toBe(false)
  })

  it("wakes OpenCode for a steer the execution finished without, inside the same turn", async () => {
    const s = setup()
    const turn = run(s.handle.prompt("first"))
    await s.requested(isPrompt("msg_1"))
    s.queue.push(delivered("msg_1"))
    await expect(run(s.handle.steer!("late steer"))).resolves.toBe(true)
    const steerPosts = () => s.requests.filter(isPrompt("msg_2")).length
    expect(steerPosts()).toBe(1)
    s.queue.push(terminal("succeeded"))
    const wake = await s.requested(
      (request) => isPrompt("msg_2")(request) && request.body?.resume === undefined
    )
    expect(wake.body).toEqual({ text: "late steer", id: "msg_2", delivery: "steer" })
    s.queue.push(delivered("msg_2"), text("after the wake"), terminal("succeeded"))
    await expect(turn).resolves.toEqual({ stopReason: "end_turn" })
    const order = s.events.map((entry) => payload(entry).turnState ?? payload(entry).sessionUpdate)
    expect(order.indexOf("agent_message_chunk")).toBeLessThan(order.indexOf("ended"))
    expect(turnStates(s.events)).toEqual(["started", "ended"])
  })

  it("reports a steer OpenCode refused as not landed", async () => {
    const s = setup({
      respond: (request) => {
        if (request.body?.resume === false) throw new Error("conflict")
        return undefined
      }
    })
    const turn = run(s.handle.prompt("first"))
    await s.requested(isPrompt("msg_1"))
    s.queue.push(delivered("msg_1"))
    await expect(run(s.handle.steer!("refused"))).resolves.toBe(false)
    s.queue.push(terminal("succeeded"))
    await expect(turn).resolves.toEqual({ stopReason: "end_turn" })
    expect(s.requests.filter(isPrompt("msg_2"))).toHaveLength(1)
  })

  it("cancels a running turn, withdraws undelivered steers and fails its open tools", async () => {
    const s = setup({
      respond: (request) =>
        request.path === `${PATH}/interrupt` ? { interrupted: true } : undefined
    })
    const turn = run(s.handle.prompt("work"))
    await s.requested(isPrompt("msg_1"))
    s.queue.push(
      delivered("msg_1"),
      event("session.tool.input.started", { sessionID: ROOT, id: "call_1", name: "shell" })
    )
    await s.emitted((entry) => payload(entry).sessionUpdate === "tool_call")
    await expect(run(s.handle.steer!("never mind"))).resolves.toBe(true)
    const cancelled = run(s.handle.cancel)
    await s.requested((request) => request.path === `${PATH}/interrupt`)
    expect(s.requests.map((request) => `${request.method} ${request.path}`)).toContain(
      `DELETE ${PATH}/inbox/msg_2`
    )
    await expect(run(s.handle.steer!("during cancel"))).resolves.toBe(false)
    s.queue.push(terminal("interrupted"))
    await expect(cancelled).resolves.toEqual({ runtimeState: "reusable" })
    await expect(turn).resolves.toEqual({ stopReason: "cancelled" })
    expect(s.updates("tool_call_update")).toEqual([
      expect.objectContaining({
        toolCallId: "call_1",
        status: "failed",
        rawOutput: { metadata: {}, error: "Cancelled" }
      })
    ])
  })

  it("withdraws a prompt OpenCode has not started when cancelled", async () => {
    const s = setup({
      respond: (request) =>
        request.path === `${PATH}/interrupt` ? { interrupted: false } : undefined
    })
    const turn = run(s.handle.prompt("queued"))
    await s.requested(isPrompt("msg_1"))
    await run(s.handle.cancel)
    await expect(turn).resolves.toEqual({ stopReason: "cancelled" })
    expect(s.requests.map((request) => `${request.method} ${request.path}`)).toContain(
      `DELETE ${PATH}/inbox/msg_1`
    )
  })

  it("ends a turn waiting to wake a steer when it is cancelled", async () => {
    let releaseWake!: () => void
    const wakeHeld = new Promise<void>((resolve) => {
      releaseWake = resolve
    })
    const s = setup({
      respond: (request) =>
        request.body?.id === "msg_2" && request.body.resume === undefined ? wakeHeld : undefined
    })
    const turn = run(s.handle.prompt("first"))
    await s.requested(isPrompt("msg_1"))
    s.queue.push(delivered("msg_1"))
    await run(s.handle.steer!("late"))
    s.queue.push(terminal("succeeded"))
    await s.requested((request) => isPrompt("msg_2")(request) && request.body?.resume === undefined)
    await run(s.handle.cancel)
    releaseWake()
    await expect(turn).resolves.toEqual({ stopReason: "cancelled" })
    expect(s.requests.some((request) => request.path === `${PATH}/interrupt`)).toBe(false)
  })

  it("maps OpenCode failures to sign-in, usage-limit and error outcomes", async () => {
    const auth = await failing({ type: "provider.auth", message: "Reconnect" })
    expect(auth.result).toMatchObject({
      success: { stopReason: "end_turn", stopKind: "authRequired" }
    })
    expect(auth.ended[0]).toMatchObject({
      stopDetail: "OpenCode isn't signed in. Sign in to continue."
    })
    const limit = await failing({
      type: "provider.api",
      message: "The usage limit has been reached. Try again in 2 hours."
    })
    expect(limit.result).toMatchObject({
      success: { stopKind: "usageLimit", resetsAt: expect.any(String) }
    })
    const refused = await failing({ type: "provider.content-filter", message: "" })
    expect(refused.result).toMatchObject({ success: { stopReason: "refusal" } })
  })

  it.each([
    [
      "a 403 OpenCode reports as an auth error",
      { type: "provider.auth", message: "Your organization has disabled access", status: 403 },
      { stopKind: "forbidden", stopDetail: "Your organization has disabled access" }
    ],
    [
      "a provider permission error",
      { type: "provider.invalid-request", message: "permission_error: Request not allowed" },
      { stopKind: "forbidden", stopDetail: "permission_error: Request not allowed" }
    ],
    [
      "a provider server error",
      { type: "provider.internal", message: "Model exploded", status: 500 },
      { stopKind: "harnessFailed", stopDetail: "Model exploded" }
    ],
    [
      "an error without a message",
      { type: "unknown", message: "" },
      { stopKind: "harnessFailed", stopDetail: "OpenCode prompt failed" }
    ]
  ])("ends the turn with the failure kind for %s", async (_, error, stop) => {
    const failed = await failing(error)
    expect(failed.result).toMatchObject({ success: { stopReason: "end_turn", ...stop } })
    expect(failed.ended[0]).toMatchObject(stop)
  })

  it("fails the running turn and later prompts once the event stream ends", async () => {
    const s = setup()
    const turn = run(Effect.result(s.handle.prompt("go")))
    await s.requested(isPrompt("msg_1"))
    s.queue.end()
    expect(await turn).toMatchObject({ failure: { message: "OpenCode's event stream ended" } })
    expect(await run(Effect.result(s.handle.prompt("again")))).toMatchObject({
      failure: { message: "OpenCode's event stream ended" }
    })
    await expect(run(s.handle.steer!("steer"))).resolves.toBe(false)
  })

  it("rejects a second prompt while one is running and recovers from a refused submission", async () => {
    let refuse = true
    const s = setup({
      respond: (request) => {
        if (request.path === `${PATH}/prompt` && refuse) {
          refuse = false
          throw new Error("Session not found")
        }
        return undefined
      }
    })
    expect(await run(Effect.result(s.handle.prompt("first")))).toMatchObject({
      failure: { message: "Session not found" }
    })
    const turn = run(s.handle.prompt("second"))
    await s.requested(isPrompt("msg_2"))
    expect(await run(Effect.result(s.handle.prompt("third")))).toMatchObject({
      failure: { message: "OpenCode is already running a turn in this session." }
    })
    s.queue.push(delivered("msg_2"), terminal("succeeded"))
    await expect(turn).resolves.toEqual({ stopReason: "end_turn" })
  })

  it("runs slash commands and compaction through their own endpoints", async () => {
    const s = setup()
    const command = run(s.handle.prompt("/review HEAD~1"))
    expect((await s.requested((request) => request.path === `${PATH}/command`)).body).toEqual({
      text: "HEAD~1",
      name: "review",
      delivery: "steer"
    })
    s.queue.push(text("reviewing"), terminal("succeeded"))
    await expect(command).resolves.toEqual({ stopReason: "end_turn" })
    expect(s.updates("agent_message_chunk")).toHaveLength(1)

    const compact = run(s.handle.prompt("/compact"))
    expect((await s.requested((request) => request.path === `${PATH}/compact`)).body).toEqual({
      id: "msg_2",
      delivery: "steer"
    })
    s.queue.push(delivered("msg_2"), terminal("succeeded"))
    await expect(compact).resolves.toEqual({ stopReason: "end_turn" })
  })
})
