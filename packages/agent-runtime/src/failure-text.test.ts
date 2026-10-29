import { describe, expect, it } from "vitest"

import { plainFailureText, withPlainFailureText } from "./failure-text.js"

describe("plain failure text", () => {
  it.each([
    [
      "Claude Code returned an error result: No conversation found with session ID: 74097ee6",
      "Claude Code couldn't find this chat's saved conversation."
    ],
    ["Query closed before response received", "Claude Code stopped unexpectedly."],
    ["Claude Code process exited with code 1", "Claude Code stopped unexpectedly."],
    ["Claude Code process terminated by signal SIGKILL", "Claude Code stopped unexpectedly."],
    [
      "Claude Code process exited with code 1. stderr: Error: Invalid model name",
      "Claude Code stopped: Error: Invalid model name"
    ],
    ["ACP connection closed", "The agent stopped unexpectedly."],
    ["Claude Code returned an error result: Invalid settings file", "Invalid settings file"],
    ["  Rate limited by the Claude API.  ", "Rate limited by the Claude API."]
  ])("shows %j as %j", (raw, plain) => {
    expect(plainFailureText(raw)).toBe(plain)
  })

  it("rewrites the error and stop detail an agent reports, and nothing else", () => {
    const error = {
      kind: "session.error",
      payload: { message: "ACP connection closed" },
      subjectId: "s"
    } as const
    const stop = {
      kind: "session.updated",
      payload: { stopDetail: "Query closed before response received", turnState: "ended" },
      subjectId: "s"
    } as const
    const output = {
      kind: "session.output",
      payload: { message: "ACP connection closed" },
      subjectId: "s"
    } as const

    expect(withPlainFailureText(error).payload).toEqual({
      message: "The agent stopped unexpectedly."
    })
    expect(withPlainFailureText(stop).payload).toEqual({
      stopDetail: "Claude Code stopped unexpectedly.",
      turnState: "ended"
    })
    expect(withPlainFailureText(output)).toBe(output)
  })
})
