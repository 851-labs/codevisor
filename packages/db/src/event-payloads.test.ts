import { describe, expect, it } from "vitest"

import { backgroundTasksFromRaw, pendingQuestionFromRaw } from "./event-payloads.js"

describe("stored session payload columns", () => {
  it("drops a stored question that no longer matches the question payload shape", () => {
    const question = {
      sessionUpdate: "question",
      questionId: "q",
      questions: [{ id: "a", question: "Continue?", options: [], allowsOther: false }]
    }
    expect(pendingQuestionFromRaw(JSON.stringify(question))).toEqual(question)
    expect(pendingQuestionFromRaw(JSON.stringify({ ...question, questions: [{}] }))).toBeUndefined()
  })

  it("keeps only well-formed background tasks", () => {
    const task = { id: "t", description: "Build", status: "running", taskType: "subagent" }
    expect(backgroundTasksFromRaw(JSON.stringify([task, { id: "partial" }]))).toEqual([task])
    expect(backgroundTasksFromRaw(JSON.stringify({ tasks: [task] }))).toEqual([])
  })
})
