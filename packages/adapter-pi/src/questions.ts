import type { QuestionAnswer } from "@codevisor/agent-runtime"
import type { QuestionSpec } from "@codevisor/api"

/// Pi extensions ask the user through dialog requests (`select`, `confirm`,
/// `input`, `editor`); each becomes one Codevisor question. Pi's other
/// extension UI requests (notifications, status, widgets, titles) have no
/// answer and nowhere to show, so they are dropped.

const QUESTION_ID = "answer"

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

export interface PiDialogQuestion {
  readonly spec: QuestionSpec
  readonly message?: string
  /// The `extension_ui_response` fields for the user's answer.
  readonly response: (answer: QuestionAnswer) => Record<string, unknown>
}

export const dialogQuestion = (request: Record<string, unknown>): PiDialogQuestion | undefined => {
  const question = text(request.title) ?? "Pi has a question"
  const message = text(request.message) ?? text(request.prefill)
  const chosen = (answer: QuestionAnswer): string | undefined =>
    answer.outcome === "answered" ? answer.answers?.[QUESTION_ID]?.answers[0] : undefined
  const reply =
    (fields: (value: string) => Record<string, unknown>) =>
    (answer: QuestionAnswer): Record<string, unknown> => {
      const value = chosen(answer)
      return value === undefined ? { cancelled: true } : fields(value)
    }
  const spec = (options: ReadonlyArray<string>, allowsOther: boolean): QuestionSpec => ({
    id: QUESTION_ID,
    question,
    options: options.map((label) => ({ label })),
    allowsOther
  })
  const context = message === undefined ? {} : { message }
  switch (request.method) {
    case "select": {
      const options = Array.isArray(request.options)
        ? request.options.filter((option): option is string => typeof option === "string")
        : []
      return { spec: spec(options, false), ...context, response: reply((value) => ({ value })) }
    }
    case "confirm":
      return {
        spec: spec(["Yes", "No"], false),
        ...context,
        response: reply((value) => ({ confirmed: value === "Yes" }))
      }
    case "input":
    case "editor":
      return { spec: spec([], true), ...context, response: reply((value) => ({ value })) }
    default:
      return undefined
  }
}
