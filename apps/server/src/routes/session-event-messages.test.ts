import type { ExecutionJob } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import {
  combinedEventText,
  jobFinishedMessage,
  REPORT_LIMIT,
  turnEndedMessage,
  waitingForUserMessage
} from "./session-event-messages.js"

const target = { id: "s1", title: 'Fix "login" <now>' }

const job = (overrides: Partial<ExecutionJob>): ExecutionJob => ({
  jobId: "j1",
  sessionId: "s1",
  description: "Wait",
  state: "completed",
  startedAt: "2026-10-19T00:00:00.000Z",
  elapsedMs: 1,
  running: [],
  logs: [],
  outputPath: "/tmp/j1.log",
  ...overrides
})

describe("session event messages", () => {
  it("escapes attributes, truncates long replies, and keys events per target", () => {
    const message = turnEndedMessage(target, undefined, "x".repeat(REPORT_LIMIT + 1), "sub-1")

    expect(message.key).toBe("turn_ended:s1")
    expect(message.text.split("\n")[0]).toBe(
      '<codevisor-event type="session.turn_ended" sessionId="s1" title="Fix &quot;login&quot; &lt;now>" subscriptionId="sub-1">'
    )
    expect(message.text).toContain("…(truncated)")
  })

  it("describes a plan approval wait without a question", () => {
    expect(waitingForUserMessage(target, "planApproval", undefined).text).toContain(
      "The session is waiting for plan approval."
    )
    expect(waitingForUserMessage(target, "question", undefined).text).toContain(
      "The session is waiting for an answer."
    )
    expect(
      waitingForUserMessage(target, "question", {
        sessionUpdate: "question",
        questionId: "q2",
        message: "Before I push",
        questions: []
      }).text
    ).toContain('{"questionId":"q2","message":"Before I push","questions":[]}')
  })

  it("reports failed and unserializable job outcomes", () => {
    const circular: Record<string, unknown> = {}
    circular.self = circular

    expect(jobFinishedMessage(job({ state: "failed", error: "boom" })).text).toContain(
      "Error: boom"
    )
    expect(jobFinishedMessage(job({ state: "cancelled" })).text).toContain("Error: cancelled")
    expect(jobFinishedMessage(job({ result: circular })).text).toContain("Result: [object Object]")
    expect(jobFinishedMessage(job({})).text).toContain("Result: undefined")
  })

  it("joins several events into one prompt", () => {
    const first = turnEndedMessage(target, "end_turn", "")
    const second = turnEndedMessage({ id: "s2", title: "Other" }, undefined, "done")

    expect(combinedEventText([first, second])).toBe(`${first.text}\n\n${second.text}`)
    expect(first.text).toContain('stopReason="end_turn"')
    expect(first.text).toContain("(no final message)")
  })
})
