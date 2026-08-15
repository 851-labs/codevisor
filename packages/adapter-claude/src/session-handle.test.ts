import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run,
  settle,
  streamEvent,
  systemMessage
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("cancels: interrupt settles open tool calls and ends the turn cancelled", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()
    fake.push(
      streamEvent({
        content_block: { id: "tool-9", name: "Bash", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    await settle()
    const cancellation = run(created.handle.cancel)
    await settle()
    fake.push(resultMessage("error_during_execution"))
    await expect(cancellation).resolves.toEqual({ runtimeState: "reusable" })
    expect(fake.interrupts).toHaveLength(1)
    const result = await promptPromise
    expect(result.stopReason).toBe("cancelled")

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "cancelled",
        toolCallId: "tool-9"
      })
    )
    // A cancelled turn is not an error.
    expect(events.every((event) => event.kind !== "session.error")).toBe(true)
  })

  it("force-ends and retires when interrupt is acknowledged without a terminal result", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake, undefined, undefined, { cancelGraceMs: 5 })
    const events: Array<RuntimeEvent> = []
    let releaseTerminal: (() => void) | undefined
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
      const payload = event.payload as Record<string, unknown>
      if (payload.turnState === "ended") {
        await new Promise<void>((resolvePromise) => {
          releaseTerminal = resolvePromise
        })
      }
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    const promptPromise = run(created.handle.prompt("do work"))
    await settle()
    fake.push(
      streamEvent({
        content_block: { id: "tool-stuck", name: "Bash", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    fake.push(
      systemMessage("task_started", {
        description: "long-running verification",
        task_id: "background-stuck",
        task_type: "shell",
        tool_use_id: "tool-stuck"
      })
    )
    await settle()

    let cancelSettled = false
    const cancellation = run(created.handle.cancel).then((result) => {
      cancelSettled = true
      return result
    })
    await vi.waitFor(() => {
      expect(releaseTerminal).toBeTypeOf("function")
    })
    expect(cancelSettled).toBe(false)
    releaseTerminal?.()

    await expect(cancellation).resolves.toEqual({ runtimeState: "retire" })
    await expect(promptPromise).resolves.toEqual({ stopReason: "cancelled" })
    expect(fake.options?.abortController?.signal.aborted).toBe(true)
    expect(
      events.filter((event) => {
        const payload = event.payload as Record<string, unknown>
        return payload.turnState === "ended"
      })
    ).toHaveLength(1)
    expect(events).toContainEqual(
      expect.objectContaining({
        payload: expect.objectContaining({
          sessionUpdate: "tool_call_update",
          status: "cancelled",
          toolCallId: "tool-stuck"
        })
      })
    )
    const backgroundSnapshots = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => Array.isArray(payload.backgroundTasks))
      .map((payload) => payload.backgroundTasks as Array<unknown>)
    expect(backgroundSnapshots.at(-1)).toEqual([])
  })

  it("force-ends when interrupt hangs or throws, and concurrent cancels share recovery", async () => {
    for (const interruptImplementation of [
      () => new Promise<void>(() => undefined),
      () => Promise.reject(new Error("control channel failed"))
    ]) {
      const fake = new FakeQuery()
      fake.interruptImplementation = interruptImplementation
      const provider = makeProvider(fake, undefined, undefined, { cancelGraceMs: 5 })
      const events: Array<RuntimeEvent> = []
      const createPromise = run(
        provider.createSession(definition, "/tmp", async (event) => {
          events.push(event)
        })
      )
      await settle()
      fake.push(initMessage())
      const created = await createPromise
      const promptPromise = run(created.handle.prompt("stay stuck"))
      await settle()

      const first = run(created.handle.cancel)
      const duplicate = run(created.handle.cancel)
      await expect(Promise.all([first, duplicate])).resolves.toEqual([
        { runtimeState: "retire" },
        { runtimeState: "retire" }
      ])
      await expect(promptPromise).resolves.toEqual({ stopReason: "cancelled" })
      expect(fake.interrupts).toHaveLength(1)
      expect(
        events.filter((event) => {
          const payload = event.payload as Record<string, unknown>
          return payload.turnState === "ended"
        })
      ).toHaveLength(1)
    }
  })

  it("retires when the SDK iterator closes during cancellation", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake, undefined, undefined, { cancelGraceMs: 50 })
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    const promptPromise = run(created.handle.prompt("stop while closing"))
    await settle()

    const cancellation = run(created.handle.cancel)
    fake.finish()

    await expect(cancellation).resolves.toEqual({ runtimeState: "retire" })
    await expect(promptPromise).resolves.toEqual({ stopReason: "cancelled" })
    expect(
      events.filter((event) => {
        const payload = event.payload as Record<string, unknown>
        return payload.turnState === "ended"
      })
    ).toHaveLength(1)
  })

  it("ignores late SDK results after forced retirement", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake, undefined, undefined, { cancelGraceMs: 1 })
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    const promptPromise = run(created.handle.prompt("get stuck"))
    await settle()
    await expect(run(created.handle.cancel)).resolves.toEqual({ runtimeState: "retire" })
    await promptPromise
    const countBeforeLateResult = events.length

    fake.push(resultMessage())
    fake.push(streamEvent({ message: { id: "phantom" }, type: "message_start" }))
    await settle()

    expect(events).toHaveLength(countBeforeLateResult)
    expect(
      events.filter((event) => {
        const payload = event.payload as Record<string, unknown>
        return payload.turnState === "ended"
      })
    ).toHaveLength(1)
  })
})
