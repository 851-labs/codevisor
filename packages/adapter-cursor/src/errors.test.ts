import { describe, expect, it } from "vitest"
import { couldBeCursorTerminalError, parseCursorTerminalError } from "./errors.js"

describe("Cursor terminal errors", () => {
  it("classifies Cursor's typed ACP error sentinels", () => {
    expect(parseCursorTerminalError("Error: RetriableError: [unavailable] Error")).toEqual({
      kind: "retriable",
      message: "Cursor is temporarily unavailable.",
      rawDetail: "[unavailable] Error",
      retryable: true
    })
    expect(parseCursorTerminalError("Error: NonRetriableError: Invalid request")).toEqual({
      kind: "non_retriable",
      message: "Invalid request",
      rawDetail: "Invalid request",
      retryable: false
    })
    expect(parseCursorTerminalError("Error: CancelledError: Request cancelled")).toMatchObject({
      kind: "cancelled",
      retryable: false
    })
  })

  it("holds only possible leading sentinels", () => {
    expect(couldBeCursorTerminalError("\n\nError: Retriable")).toBe(true)
    expect(couldBeCursorTerminalError("Error: RetriableError: [unavailable] Error")).toBe(true)
    expect(couldBeCursorTerminalError("This text mentions RetriableError safely.")).toBe(false)
    expect(parseCursorTerminalError("This text mentions RetriableError safely.")).toBeUndefined()
  })
})
