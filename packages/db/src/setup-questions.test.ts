import { describe, expect, it } from "vitest"

import { setupQuestionPresentation } from "./setup-questions.js"

describe("setup question presentation", () => {
  it("finds the setup presentation among the questions", () => {
    expect(
      setupQuestionPresentation({
        questions: [{ presentation: "markdown" }, { presentation: "computerUsePermissions" }]
      })
    ).toBe("computerUsePermissions")
  })

  it("ignores events without a question list", () => {
    expect(setupQuestionPresentation(undefined)).toBeUndefined()
    expect(setupQuestionPresentation({ questions: "computerUsePermissions" })).toBeUndefined()
  })
})
