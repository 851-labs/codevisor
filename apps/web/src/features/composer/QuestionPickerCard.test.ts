import { describe, expect, it } from "vitest"

import type { QuestionSpecInfo } from "../../lib/session-events"
import {
  areQuestionAnswersSubmittable,
  buildQuestionAnswers,
  selectionsWithHighlightedSingleSelect
} from "./QuestionPickerCard"

const approachQuestion: QuestionSpecInfo = {
  id: "approach",
  question: "How should we proceed?",
  options: [
    { label: "Match macOS", description: "Use the native app as source of truth" },
    { label: "Keep web defaults", description: "Prefer browser behavior" }
  ],
  allowsOther: true
}

describe("QuestionPickerCard answers", () => {
  it("builds answers from the Return-committed single-select snapshot", () => {
    const committed = selectionsWithHighlightedSingleSelect({}, approachQuestion, 1)

    expect(buildQuestionAnswers([approachQuestion], committed, {})).toEqual({
      approach: { answers: ["Keep web defaults"] }
    })
  })

  it("keeps Other unsubmittable until its note has text", () => {
    const otherSelected = selectionsWithHighlightedSingleSelect({}, approachQuestion, 2)

    expect(areQuestionAnswersSubmittable([approachQuestion], otherSelected, {})).toBe(false)
    expect(
      areQuestionAnswersSubmittable([approachQuestion], otherSelected, {
        approach: "Use project conventions."
      })
    ).toBe(true)
    expect(
      buildQuestionAnswers([approachQuestion], otherSelected, {
        approach: "Use project conventions."
      })
    ).toEqual({
      approach: { answers: [], note: "Use project conventions." }
    })
  })
})
