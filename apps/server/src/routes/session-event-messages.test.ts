import type { ExecutionJob } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import {
  combinedEventText,
  erroredMessage,
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
  it("escapes attributes, keeps the whole final reply, and keys events per target", () => {
    const reply = "x".repeat(REPORT_LIMIT + 1)
    const message = turnEndedMessage(target, { stopReason: undefined, finalText: reply }, "sub-1")

    expect(message.key).toBe("turn_ended:s1")
    expect(message.text.split("\n")).toEqual([
      '<codevisor-event type="session.turn_ended" agentId="s1" title="Fix &quot;login&quot; &lt;now>" subscriptionId="sub-1">',
      reply,
      "</codevisor-event>"
    ])
  })

  it("reports a usage-limit pause instead of an empty final message", () => {
    const usageLimitDetail = "You've hit your session limit · resets 4:30pm."
    const empty = turnEndedMessage(target, {
      stopReason: "end_turn",
      finalText: "",
      usageLimitDetail
    })
    const partial = turnEndedMessage(target, {
      stopReason: "end_turn",
      finalText: "Half done.",
      usageLimitDetail
    })
    const paused = `Paused at its usage limit: ${usageLimitDetail}\nIt continues on its own once usage is available.`

    expect(empty.text.split("\n")).toEqual([
      '<codevisor-event type="session.turn_ended" agentId="s1" title="Fix &quot;login&quot; &lt;now>" stopReason="end_turn" stopKind="usageLimit">',
      ...paused.split("\n"),
      "</codevisor-event>"
    ])
    expect(partial.text).toContain(`Half done.\n\n${paused}`)
  })

  it("truncates a long error report", () => {
    const message = erroredMessage(target, "x".repeat(REPORT_LIMIT + 1))

    expect(message.text).toContain(`${"x".repeat(REPORT_LIMIT)}\n…(truncated)`)
    expect(message.text).not.toContain("x".repeat(REPORT_LIMIT + 1))
  })

  it("describes a plan approval wait without a question", () => {
    expect(waitingForUserMessage(target, "planApproval", undefined).text).toContain(
      "The agent is waiting for plan approval."
    )
    expect(waitingForUserMessage(target, "question", undefined).text).toContain(
      "The agent is waiting for an answer."
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
    const first = turnEndedMessage(target, { stopReason: "end_turn", finalText: "" })
    const second = turnEndedMessage(
      { id: "s2", title: "Other" },
      { stopReason: undefined, finalText: "done" }
    )

    expect(combinedEventText([first, second])).toBe(`${first.text}\n\n${second.text}`)
    expect(first.text).toContain('stopReason="end_turn"')
    expect(first.text).toContain("(no final message)")
  })
})
