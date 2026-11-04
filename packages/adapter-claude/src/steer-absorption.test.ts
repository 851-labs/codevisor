import { STEER_SETTLED_UPDATE, type RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import { INTERRUPTED_STEP_PREFIX } from "./step-interrupts.js"
import {
  payloadOf,
  resultMessage,
  run,
  sdkMessage,
  startTestSession,
  streamEvent,
  type FakeQuery
} from "./test-support.js"

const messageStart = (id: string) => streamEvent({ message: { id }, type: "message_start" })

const toolResult = (toolUseId: string) =>
  sdkMessage({
    message: {
      content: [{ content: "done", tool_use_id: toolUseId, type: "tool_result" }],
      role: "user"
    },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "user"
  })

const settlements = (events: ReadonlyArray<RuntimeEvent>) =>
  events.map(payloadOf).filter((payload) => payload.sessionUpdate === STEER_SETTLED_UPDATE)

const runningTool = async (fake: FakeQuery, toolUseId: string): Promise<void> => {
  fake.push(messageStart("msg-tool"))
  fake.push(
    streamEvent({
      content_block: { id: toolUseId, name: "Bash", type: "tool_use" },
      index: 0,
      type: "content_block_start"
    })
  )
  await fake.drain()
}

const steerOf = (created: Awaited<ReturnType<typeof startTestSession>>["created"]) => {
  const steer = created.handle.steer
  if (steer === undefined) throw new Error("Claude sessions steer")
  return steer
}

const interruptStepOf = (created: Awaited<ReturnType<typeof startTestSession>>["created"]) => {
  const interruptStep = created.handle.interruptStep
  if (interruptStep === undefined) throw new Error("Claude sessions interrupt a step")
  return interruptStep
}

const receivedTexts = (fake: FakeQuery) =>
  fake.receivedMessages.map(({ message }) =>
    typeof message.content === "string"
      ? message.content
      : message.content.map((block) => (block.type === "text" ? block.text : block.type)).join("")
  )

describe("Claude steer absorption", () => {
  it("reports a steer as absorbed only once the response after the running tool starts", async () => {
    const { fake, events, created } = await startTestSession()
    const promptPromise = run(created.handle.prompt("run the checks"))
    await fake.nextPrompt()
    await runningTool(fake, "tool-checks")

    await expect(run(steerOf(created)("make the bot mode a select", "queue-1"))).resolves.toBe(true)
    fake.push(toolResult("tool-checks"))
    await fake.drain()
    expect(settlements(events)).toEqual([])

    fake.push(messageStart("msg-after-tool"))
    await fake.drain()
    expect(settlements(events)).toEqual([
      {
        sessionUpdate: STEER_SETTLED_UPDATE,
        steerId: "queue-1",
        outcome: "absorbed",
        startsTurn: false
      }
    ])
    fake.push(resultMessage("success"))
    await promptPromise
  })

  it("waits for one more response when the steer lands while a request is already on its way", async () => {
    const { fake, events, created } = await startTestSession()
    const promptPromise = run(created.handle.prompt("run the checks"))
    await fake.nextPrompt()
    await runningTool(fake, "tool-checks")
    fake.push(toolResult("tool-checks"))
    await fake.drain()

    await run(steerOf(created)("one more thing", "queue-2"))
    fake.push(messageStart("msg-in-flight"))
    await fake.drain()
    expect(settlements(events)).toEqual([])

    fake.push(messageStart("msg-next"))
    await fake.drain()
    expect(settlements(events).map((payload) => payload.steerId)).toEqual(["queue-2"])
    fake.push(resultMessage("success"))
    await promptPromise
  })

  it("starts a user turn when Claude takes a steer after an interrupt ended the turn", async () => {
    const { fake, events, created } = await startTestSession()
    const promptPromise = run(created.handle.prompt("run the checks"))
    await fake.nextPrompt()
    await runningTool(fake, "tool-checks")
    await run(steerOf(created)("do this instead", "queue-3"))

    const cancellation = run(created.handle.cancel)
    await fake.waitFor(() => fake.interrupts.length === 1)
    fake.push(resultMessage("error_during_execution"))
    await cancellation
    await promptPromise
    fake.push(messageStart("msg-steer"))
    await fake.drain()

    const tail = events.map(payloadOf).slice(-2)
    expect(tail[0]).toMatchObject({ outcome: "absorbed", startsTurn: true, steerId: "queue-3" })
    expect(tail[1]).toMatchObject({ initiatedBy: "user", turnState: "started" })
  })

  it("interrupts only the running step so Claude reads the steer inside the same turn", async () => {
    const { fake, events, created } = await startTestSession()
    const promptPromise = run(created.handle.prompt("run the checks"))
    await fake.nextPrompt()
    await runningTool(fake, "tool-checks")
    await run(steerOf(created)("do this instead", "queue-5"))

    await expect(run(interruptStepOf(created))).resolves.toBe(true)
    expect(fake.interrupts).toHaveLength(1)
    fake.push(resultMessage("error_during_execution"))
    fake.push(messageStart("msg-steer"))
    await fake.drain()

    expect(settlements(events)).toEqual([
      {
        sessionUpdate: STEER_SETTLED_UPDATE,
        steerId: "queue-5",
        outcome: "absorbed",
        startsTurn: false
      }
    ])
    expect(events.map(payloadOf).filter((payload) => payload.turnState === "ended")).toEqual([])
    fake.push(resultMessage("success"))
    await expect(promptPromise).resolves.toMatchObject({ stopReason: "end_turn" })
  })

  it("prefixes the interrupted steer with a note only Claude reads", async () => {
    const { fake, events, created } = await startTestSession()
    void run(created.handle.prompt("run the checks"))
    await fake.nextPrompt()
    await runningTool(fake, "tool-checks")
    await run(steerOf(created)("do this instead", "queue-6"))
    await run(steerOf(created)("and then this", "queue-7"))

    await run(interruptStepOf(created))

    expect(receivedTexts(fake)).toEqual([
      "run the checks",
      `${INTERRUPTED_STEP_PREFIX}do this instead`,
      "and then this"
    ])
    expect(JSON.stringify(events)).not.toContain(INTERRUPTED_STEP_PREFIX)
  })

  it("leaves a steer Claude has already taken in to reach it without an interrupt", async () => {
    const { fake, created } = await startTestSession()
    void run(created.handle.prompt("run the checks"))
    await fake.nextPrompt()
    await runningTool(fake, "tool-checks")
    await run(steerOf(created)("do this instead", "queue-8"))
    fake.takeQueuedMessages()

    await expect(run(interruptStepOf(created))).resolves.toBe(true)

    expect(fake.interrupts).toEqual([])
    expect(receivedTexts(fake)).toEqual(["run the checks", "do this instead"])
  })

  it("declines to interrupt a step when no steer is waiting", async () => {
    const { fake, created } = await startTestSession()
    void run(created.handle.prompt("run the checks"))
    await fake.nextPrompt()

    await expect(run(interruptStepOf(created))).resolves.toBe(false)
    expect(fake.interrupts).toEqual([])
  })

  it("reports pending steers as dropped when the session closes", async () => {
    const { fake, events, created } = await startTestSession()
    void run(created.handle.prompt("run the checks"))
    await fake.nextPrompt()
    await runningTool(fake, "tool-checks")
    await run(steerOf(created)("never read", "queue-4"))

    await run(created.handle.close)

    expect(settlements(events)).toEqual([
      {
        sessionUpdate: STEER_SETTLED_UPDATE,
        steerId: "queue-4",
        outcome: "dropped",
        startsTurn: false
      }
    ])
  })
})
