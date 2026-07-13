import { describe, expect, it } from "vitest"

import {
  recordTodoCompletionState,
  rememberTodoExpansionState,
  todoExpansionState
} from "./useTodoExpansionState"

describe("todo expansion state", () => {
  it("defaults to expanded and remembers each session independently", () => {
    expect(todoExpansionState("todo-default")).toBe(true)

    rememberTodoExpansionState("todo-collapsed", false)
    rememberTodoExpansionState("todo-expanded", true)

    expect(todoExpansionState("todo-collapsed")).toBe(false)
    expect(todoExpansionState("todo-expanded")).toBe(true)
  })

  it("collapses once when a checklist finishes and allows it to be reopened", () => {
    const sessionId = "todo-auto-collapse"

    expect(recordTodoCompletionState(sessionId, false)).toBe(false)
    expect(recordTodoCompletionState(sessionId, true)).toBe(true)
    expect(todoExpansionState(sessionId)).toBe(false)

    rememberTodoExpansionState(sessionId, true)
    expect(recordTodoCompletionState(sessionId, true)).toBe(false)
    expect(todoExpansionState(sessionId)).toBe(true)

    expect(recordTodoCompletionState(sessionId, false)).toBe(false)
    expect(recordTodoCompletionState(sessionId, true)).toBe(true)
    expect(todoExpansionState(sessionId)).toBe(false)
  })
})
