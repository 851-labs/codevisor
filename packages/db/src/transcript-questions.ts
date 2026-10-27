import { jsonRecord, type JsonRecord } from "./event-payloads.js"
import { setupQuestionPresentation } from "./setup-questions.js"

const planApprovalQuestionId = "exit_plan_mode"

export const asksInTranscript = (payload: JsonRecord | undefined): boolean =>
  hasQuestions(payload) &&
  setupQuestionPresentation(payload) === undefined &&
  !asksPlanApproval(payload)

export const splitsWorkedSection = (payload: JsonRecord | undefined): boolean =>
  setupQuestionPresentation(payload) !== undefined || asksInTranscript(payload)

const hasQuestions = (payload: JsonRecord | undefined): boolean =>
  questionRecords(payload).length > 0

const asksPlanApproval = (payload: JsonRecord | undefined): boolean =>
  questionRecords(payload).some((question) => question?.id === planApprovalQuestionId)

const questionRecords = (
  payload: JsonRecord | undefined
): ReadonlyArray<JsonRecord | undefined> => {
  const questions = payload?.questions
  return (Array.isArray(questions) ? questions : []).map(jsonRecord)
}
