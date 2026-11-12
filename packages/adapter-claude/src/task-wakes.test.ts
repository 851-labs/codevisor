import { describe, expect, it } from "vitest"

import {
  payloadOf,
  resultMessage,
  run,
  startTestSession,
  streamEvent,
  systemMessage
} from "./test-support.js"

const notification = (taskId: string, summary: string, status = "completed") =>
  systemMessage("task_notification", {
    output_file: `/tmp/${taskId}.txt`,
    status,
    summary,
    task_id: taskId
  })

const agentReply = (id: string) => streamEvent({ message: { id }, type: "message_start" })

describe("Claude task wakes", () => {
  it("records the background tasks that woke an idle chat as one event prompt before the turn", async () => {
    const { fake, events } = await startTestSession()

    fake.push(notification("bg-1", 'Background command "bun run test" completed (exit code 0)'))
    fake.push(notification("bg-2", "Build failed", "failed"))
    fake.push(agentReply("msg-wake"))
    fake.push(resultMessage())
    await fake.drain()

    const payloads = events.map(payloadOf)
    const wake = payloads.findIndex((payload) => payload.role === "user")
    const started = payloads.findIndex((payload) => payload.turnState === "started")
    expect(payloads[wake]).toMatchObject({ origin: "event", role: "user", startsTurn: true })
    expect(payloads[wake]?.text).toBe(
      [
        '<codevisor-event type="harness.task_finished" taskId="bg-1" status="completed" outputFile="/tmp/bg-1.txt">',
        'Background command "bun run test" completed (exit code 0)',
        "</codevisor-event>",
        "",
        '<codevisor-event type="harness.task_finished" taskId="bg-2" status="failed" outputFile="/tmp/bg-2.txt">',
        "Build failed",
        "</codevisor-event>"
      ].join("\n")
    )
    expect(wake).toBeLessThan(started)
    expect(payloads[started]).toMatchObject({ initiatedBy: "agent" })
  })

  it("records nothing for a task that finishes inside a turn the user started", async () => {
    const { created, fake, events } = await startTestSession()

    const prompt = run(created.handle.prompt("run the tests"))
    await fake.nextPrompt()
    fake.push(agentReply("msg-user"))
    fake.push(notification("bg-1", "tests passed"))
    fake.push(resultMessage())
    await prompt
    fake.push(agentReply("msg-later"))
    fake.push(resultMessage())
    await fake.drain()

    expect(events.map(payloadOf).filter((payload) => payload.role === "user")).toEqual([])
  })
})
