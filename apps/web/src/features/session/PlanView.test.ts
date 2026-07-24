import { describe, expect, it } from "vitest"

import { todoEntryTextClassName, todoPanelIsVisible } from "./PlanView"

describe("todo entry styling", () => {
  it("matches TodoPanelView.swift status text styling", () => {
    expect(todoEntryTextClassName("completed")).toContain("text-muted-foreground")
    expect(todoEntryTextClassName("completed")).toContain("line-through")

    expect(todoEntryTextClassName("in_progress")).toContain("text-foreground")
    expect(todoEntryTextClassName("in_progress")).toContain("font-medium")

    expect(todoEntryTextClassName("pending")).toContain("text-muted-foreground")
    expect(todoEntryTextClassName("pending")).not.toContain("line-through")
    expect(todoEntryTextClassName("pending")).not.toContain("font-medium")
  })
})

describe("todo panel visibility", () => {
  it("shows only nonempty checklists with unfinished work", () => {
    expect(todoPanelIsVisible(undefined)).toBe(false)
    expect(todoPanelIsVisible([])).toBe(false)
    expect(todoPanelIsVisible([{ content: "Done", priority: "medium", status: "completed" }])).toBe(
      false
    )
    expect(
      todoPanelIsVisible([
        { content: "Done", priority: "medium", status: "completed" },
        { content: "Next", priority: "medium", status: "pending" }
      ])
    ).toBe(true)
  })
})
