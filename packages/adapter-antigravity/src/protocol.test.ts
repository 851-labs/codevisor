import { describe, expect, it } from "vitest"

import { agyResult, agyStep, messageOf } from "./protocol.js"

const noUsage = {
  input_tokens: undefined,
  output_tokens: undefined,
  thinking_tokens: undefined,
  cache_read_tokens: undefined,
  total_tokens: undefined
}

describe("agy stream parsing", () => {
  it("reads a step's known fields and drops the ones of the wrong type", () => {
    expect(
      agyStep({
        conversation_id: "c",
        step_index: 2,
        state: "DONE",
        step_type: "tool",
        tool_name: "run_command",
        text_delta: "hi",
        usage: { input_tokens: 1, output_tokens: 2, total_tokens: "3" },
        tool_info: {
          name: "run_command",
          parameters: { CommandLine: "ls" },
          output: "ok",
          error: { type: "TOOL_ERROR", message: "no" }
        }
      })
    ).toEqual({
      conversation_id: "c",
      step_index: 2,
      state: "DONE",
      step_type: "tool",
      tool_name: "run_command",
      text_delta: "hi",
      usage: { ...noUsage, input_tokens: 1, output_tokens: 2 },
      tool_info: {
        name: "run_command",
        parameters: { CommandLine: "ls" },
        output: "ok",
        error: { type: "TOOL_ERROR", message: "no" }
      }
    })
    expect(agyStep({ step_index: 0 })).toEqual({
      step_index: 0,
      state: "",
      step_type: "",
      usage: noUsage,
      tool_info: { parameters: {}, error: {} }
    })
    expect(agyStep({ step_type: "tool" })).toBeUndefined()
  })

  it("reads a result, keeping each denied action it can name", () => {
    expect(
      agyResult({
        status: "SUCCESS",
        error: "late",
        denied_actions: [{ action: "run", display_name: "Run" }, "junk"]
      })
    ).toEqual({
      status: "SUCCESS",
      error: "late",
      usage: noUsage,
      denied_actions: [{ action: "run", display_name: "Run" }, {}]
    })
    expect(agyResult(undefined)).toEqual({ status: "", usage: noUsage, denied_actions: [] })
  })

  it("describes thrown values that aren't errors", () => {
    expect(messageOf(new Error("boom"))).toBe("boom")
    expect(messageOf("plain")).toBe("plain")
  })
})
