import type { QuestionAnswer } from "@codevisor/agent-runtime"
import type { QuestionSpec } from "@codevisor/api"

const QUESTION_ID = "answer"

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

export interface PiDialogQuestion {
  readonly spec: QuestionSpec
  readonly message?: string
  readonly response: (answer: QuestionAnswer) => Record<string, unknown>
}

const chosenAnswer = (answer: QuestionAnswer): string | undefined =>
  answer.outcome === "answered" ? answer.answers?.[QUESTION_ID]?.answers[0] : undefined

const answerReply =
  (fields: (value: string) => Record<string, unknown>) =>
  (answer: QuestionAnswer): Record<string, unknown> => {
    const value = chosenAnswer(answer)
    return value === undefined ? { cancelled: true } : fields(value)
  }

export const dialogQuestion = (request: Record<string, unknown>): PiDialogQuestion | undefined => {
  const question = text(request.title) ?? "Pi has a question"
  const message = text(request.message) ?? text(request.prefill)
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
      return {
        spec: spec(options, false),
        ...context,
        response: answerReply((value) => ({ value }))
      }
    }
    case "confirm":
      return {
        spec: spec(["Yes", "No"], false),
        ...context,
        response: answerReply((value) => ({ confirmed: value === "Yes" }))
      }
    case "input":
    case "editor":
      return { spec: spec([], true), ...context, response: answerReply((value) => ({ value })) }
    default:
      return undefined
  }
}
