import { describe, expect, it } from "vitest"

import { rememberTodoExpansionState, todoExpansionState } from "./useTodoExpansionState"

describe("todo expansion state", () => {
  it("defaults to expanded and remembers each session independently", () => {
    expect(todoExpansionState("todo-default")).toBe(true)

    rememberTodoExpansionState("todo-collapsed", false)
    rememberTodoExpansionState("todo-expanded", true)

    expect(todoExpansionState("todo-collapsed")).toBe(false)
    expect(todoExpansionState("todo-expanded")).toBe(true)
  })

  it("updates a session's remembered disclosure preference", () => {
    const sessionId = "todo-disclosure"

    rememberTodoExpansionState(sessionId, false)
    expect(todoExpansionState(sessionId)).toBe(false)

    rememberTodoExpansionState(sessionId, true)
    expect(todoExpansionState(sessionId)).toBe(true)
  })
})
