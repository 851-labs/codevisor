import type { QuestionSpec } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import {
  answersIfDefined,
  answersIfPresent,
  questionIdFirstPayloads,
  questionReplyAnswer,
  questionReplyText,
  SKIPPED_FOR_REPLY,
  sessionUpdateFirstPayloads,
  type QuestionResolution
} from "./question-events.js"

const questions: ReadonlyArray<QuestionSpec> = [
  { allowsOther: false, id: "approval", options: [{ label: "Allow" }], question: "Allow?" }
]
const answers = { approval: { answers: ["Allow"] } }
const encodedQuestions = JSON.stringify(questions)
const encodedAnswers = JSON.stringify(answers)

const hiddenAnswers = (): QuestionResolution =>
  new Proxy<QuestionResolution>(
    { outcome: "answered" },
    {
      get: (target, key) => (key === "answers" ? answers : Reflect.get(target, key)),
      has: (target, key) => key !== "answers" && Reflect.has(target, key)
    }
  )

describe("question-id-first payloads", () => {
  const payloads = questionIdFirstPayloads(answersIfDefined)

  it("serializes a question with its details after the session update", () => {
    expect(JSON.stringify(payloads.asked("q1", questions))).toBe(
      `{"questionId":"q1","questions":${encodedQuestions},"sessionUpdate":"question"}`
    )
    expect(JSON.stringify(payloads.asked("q1", questions, { message: "Run ls" }))).toBe(
      `{"questionId":"q1","questions":${encodedQuestions},"sessionUpdate":"question","message":"Run ls"}`
    )
    expect(JSON.stringify(payloads.asked("q1", questions, { autoResolutionMs: 500 }))).toBe(
      `{"questionId":"q1","questions":${encodedQuestions},"sessionUpdate":"question","autoResolutionMs":500}`
    )
  })

  it("serializes a resolution with its answers last", () => {
    expect(
      JSON.stringify(payloads.resolved("q1", questions, { outcome: "answered", answers }))
    ).toBe(
      `{"outcome":"answered","questionId":"q1","questions":${encodedQuestions},"sessionUpdate":"question_resolved","answers":${encodedAnswers}}`
    )
  })

  it("omits details and answers that are undefined", () => {
    expect(
      Object.keys(
        payloads.asked("q1", questions, { message: undefined, autoResolutionMs: undefined })
      )
    ).toEqual(["questionId", "questions", "sessionUpdate"])
    expect(
      Object.keys(payloads.resolved("q1", questions, { outcome: "cancelled", answers: undefined }))
    ).toEqual(["outcome", "questionId", "questions", "sessionUpdate"])
  })
})

describe("session-update-first payloads", () => {
  const payloads = sessionUpdateFirstPayloads(answersIfDefined)

  it("serializes a question with its details before the questions", () => {
    expect(JSON.stringify(payloads.asked("q1", questions))).toBe(
      `{"sessionUpdate":"question","questionId":"q1","questions":${encodedQuestions}}`
    )
    expect(JSON.stringify(payloads.asked("q1", questions, { message: "Pick one" }))).toBe(
      `{"sessionUpdate":"question","questionId":"q1","message":"Pick one","questions":${encodedQuestions}}`
    )
    expect(JSON.stringify(payloads.asked("q1", questions, { autoResolutionMs: 500 }))).toBe(
      `{"sessionUpdate":"question","questionId":"q1","autoResolutionMs":500,"questions":${encodedQuestions}}`
    )
  })

  it("serializes a resolution with its answers last", () => {
    expect(
      JSON.stringify(payloads.resolved("q1", questions, { outcome: "answered", answers }))
    ).toBe(
      `{"sessionUpdate":"question_resolved","questionId":"q1","outcome":"answered","questions":${encodedQuestions},"answers":${encodedAnswers}}`
    )
  })

  it("omits answers for an auto-resolved question", () => {
    expect(Object.keys(payloads.resolved("q1", questions, { outcome: "autoResolved" }))).toEqual([
      "sessionUpdate",
      "questionId",
      "outcome",
      "questions"
    ])
  })
})

describe("answer rules", () => {
  it("reads defined answers whether or not the key is visible", () => {
    expect(answersIfDefined(hiddenAnswers())).toEqual({ answers })
    expect(answersIfDefined({ outcome: "answered", answers: undefined })).toEqual({})
  })

  it("keeps answers only when the key is present and defined", () => {
    expect(answersIfPresent(hiddenAnswers())).toEqual({})
    expect(answersIfPresent({ outcome: "answered", answers: undefined })).toEqual({})
    expect(answersIfPresent({ outcome: "answered", answers })).toEqual({ answers })
  })
})

describe("question reply text", () => {
  it("quotes a text-only reply as the answer", () => {
    expect(questionReplyText({ text: "  Use SQLite  " })).toBe(
      "The user replied instead: Use SQLite"
    )
  })

  it("has no answer text for an empty reply or one with attachments", () => {
    const attachment = {
      name: "a.png",
      mimeType: "image/png",
      kind: "image",
      sizeBytes: 1,
      path: "/a.png"
    } as const
    expect(questionReplyText({ text: "   " })).toBeUndefined()
    expect(questionReplyText({ text: "See this", attachments: [attachment] })).toBeUndefined()
  })

  it("gives the reply to the first question and marks the rest skipped", () => {
    expect([0, 1, 2].map((index) => questionReplyAnswer(index, "Do X"))).toEqual([
      "Do X",
      SKIPPED_FOR_REPLY,
      SKIPPED_FOR_REPLY
    ])
  })
})
