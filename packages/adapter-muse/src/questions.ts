import type { QuestionAnswer } from "@codevisor/agent-runtime"
import type { QuestionSpec } from "@codevisor/api"

import {
  commandId,
  text,
  type ApprovalChoice,
  type ApprovalRequest,
  type UserInputRequest
} from "./protocol.js"

export interface MuseRequest {
  readonly method: string
  readonly params: Record<string, unknown>
}

export interface MuseQuestionReply {
  readonly request: MuseRequest
  readonly delivered: boolean
}

export interface MuseQuestion {
  readonly specs: ReadonlyArray<QuestionSpec>
  readonly autoResolutionMs?: number
  readonly reply: (answer: QuestionAnswer) => MuseRequest
  readonly replyWithMessage: (replyText: string | undefined) => MuseQuestionReply
}

const PERMISSION_ID = "permission"
const DISMISSED_REASON = "The user dismissed the question."
const REPLIED_WITHOUT_TEXT = "The user replied instead of answering."

export const approvalQuestion = (request: ApprovalRequest): MuseQuestion => {
  const subject = text(request.subject.command) ?? text(request.subject.path)
  return {
    specs: [
      {
        id: PERMISSION_ID,
        header: "Permission",
        question: `Allow ${request.toolName}${subject === undefined ? "" : `: ${subject}`}?`,
        options: request.availableChoices.map((choice) => ({ label: choice.label })),
        allowsOther: false
      }
    ],
    reply: (answer) =>
      decide(request, chosenChoice(request, answer) ?? refusalChoice(request.availableChoices)),
    replyWithMessage: () => ({
      request: decide(request, declineChoice(request.availableChoices)),
      delivered: false
    })
  }
}

export const userInputQuestion = (request: UserInputRequest): MuseQuestion => ({
  specs: request.questions.map((question) => ({
    id: question.id,
    ...(text(question.header) === undefined ? {} : { header: question.header }),
    question: question.question,
    options: question.options.map((option) => ({
      label: option.label,
      ...(text(option.description) === undefined ? {} : { description: option.description })
    })),
    ...(question.selection.mode === "multiple" ? { multiSelect: true } : {}),
    allowsOther: true
  })),
  ...(request.autoResolutionMs === undefined ? {} : { autoResolutionMs: request.autoResolutionMs }),
  reply: (answer) => {
    if (answer.outcome !== "answered") return cancelUserInput(request, DISMISSED_REASON)
    return {
      method: "userInput/answer",
      params: {
        ...userInputParams(request),
        answers: request.questions.map((question) => {
          const entry = answer.answers?.[question.id]
          const labels = entry?.answers ?? []
          const note = entry?.note === undefined ? {} : { note: entry.note }
          const known = labels.filter((value) =>
            question.options.some((option) => option.label === value)
          )
          if (question.selection.mode === "multiple" && known.length === labels.length)
            return { questionId: question.id, selectedLabels: known, ...note }
          if (labels.length === 1 && known.length === 1)
            return { questionId: question.id, selectedLabel: known[0], ...note }
          return { questionId: question.id, freeText: labels.join("\n"), ...note }
        })
      }
    }
  },
  replyWithMessage: (replyText) => ({
    request: cancelUserInput(request, replyText ?? REPLIED_WITHOUT_TEXT),
    delivered: replyText !== undefined
  })
})

const chosenChoice = (
  request: ApprovalRequest,
  answer: QuestionAnswer
): ApprovalChoice | undefined => {
  if (answer.outcome !== "answered") return undefined
  const label = answer.answers?.[PERMISSION_ID]?.answers[0]
  return request.availableChoices.find((choice) => choice.label === label)
}

const decide = (request: ApprovalRequest, choice: ApprovalChoice | undefined): MuseRequest => {
  if (choice === undefined)
    return {
      method: "turn/interrupt",
      params: { commandId: commandId(), sessionId: request.sessionId }
    }
  return {
    method: "approval/decide",
    params: {
      commandId: commandId(),
      sessionId: request.sessionId,
      approvalId: request.approvalId,
      requirementId: request.currentRequirementId,
      choiceId: choice.choiceId
    }
  }
}

const refusalChoice = (choices: ReadonlyArray<ApprovalChoice>): ApprovalChoice | undefined =>
  choices.find((choice) => choice.decision === "abort") ??
  choices.find((choice) => choice.decision.startsWith("denied")) ??
  choices.find((choice) => !choice.decision.startsWith("approved"))

const declineChoice = (choices: ReadonlyArray<ApprovalChoice>): ApprovalChoice | undefined =>
  choices.find((choice) => choice.decision.startsWith("denied")) ?? refusalChoice(choices)

const userInputParams = (request: UserInputRequest) => ({
  commandId: commandId(),
  sessionId: request.sessionId,
  userInputId: request.userInputId
})

const cancelUserInput = (request: UserInputRequest, reason: string): MuseRequest => ({
  method: "userInput/cancel",
  params: { ...userInputParams(request), reason }
})
