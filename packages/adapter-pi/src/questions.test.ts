import { describe, expect, it } from "vitest"

import { dialogQuestion } from "./questions.js"

const answered = (value: string) => ({
  outcome: "answered" as const,
  answers: { answer: { answers: [value] } }
})
const cancelled = { outcome: "cancelled" as const }

describe("Pi dialogs as questions", () => {
  it("asks a select with its options and answers with the chosen one", () => {
    const dialog = dialogQuestion({
      method: "select",
      title: "Allow dangerous command?",
      options: ["Allow", "Block", 3]
    })!
    expect(dialog.spec).toEqual({
      id: "answer",
      question: "Allow dangerous command?",
      options: [{ label: "Allow" }, { label: "Block" }],
      allowsOther: false
    })
    expect(dialog).not.toHaveProperty("message")
    expect(dialog.response(answered("Block"))).toEqual({ value: "Block" })
    expect(dialog.response(cancelled)).toEqual({ cancelled: true })
    expect(dialog.response({ outcome: "answered" })).toEqual({ cancelled: true })
    expect(dialogQuestion({ method: "select" })!.spec.options).toEqual([])
  })

  it("asks a confirm as yes or no, with its message", () => {
    const dialog = dialogQuestion({
      method: "confirm",
      title: "Clear session?",
      message: "All lost."
    })!
    expect(dialog.message).toBe("All lost.")
    expect(dialog.spec.options).toEqual([{ label: "Yes" }, { label: "No" }])
    expect(dialog.response(answered("Yes"))).toEqual({ confirmed: true })
    expect(dialog.response(answered("No"))).toEqual({ confirmed: false })
  })

  it("asks inputs and editors as free text, showing an editor's starting text", () => {
    const input = dialogQuestion({ method: "input" })!
    expect(input.spec).toMatchObject({
      question: "Pi has a question",
      options: [],
      allowsOther: true
    })
    expect(input.response(answered("42"))).toEqual({ value: "42" })
    expect(dialogQuestion({ method: "editor", title: "Edit", prefill: "Line 1" })!.message).toBe(
      "Line 1"
    )
  })

  it("has nothing to ask for notifications and status", () => {
    for (const method of ["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"])
      expect(dialogQuestion({ method, message: "hi" })).toBeUndefined()
  })
})
