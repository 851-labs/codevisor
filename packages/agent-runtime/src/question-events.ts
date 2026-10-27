import type { QuestionSpec } from "@codevisor/api"

import type { PromptInput, QuestionAnswer } from "./types.js"

export type QuestionOutcome = QuestionAnswer["outcome"] | "autoResolved" | "replied"

export interface QuestionResolution {
  readonly outcome: QuestionOutcome
  readonly answers?: QuestionAnswer["answers"] | undefined
}

export interface QuestionDetails {
  readonly message?: string | undefined
  readonly autoResolutionMs?: number | undefined
}

export interface QuestionAskedPayload {
  readonly sessionUpdate: "question"
  readonly questionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly message?: string
  readonly autoResolutionMs?: number
}

export interface QuestionResolvedPayload {
  readonly sessionUpdate: "question_resolved"
  readonly questionId: string
  readonly outcome: QuestionOutcome
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly answers?: QuestionAnswer["answers"]
}

export type ResolvedAnswers = Pick<QuestionResolvedPayload, "answers">

export type AnswersRule = (resolution: QuestionResolution) => ResolvedAnswers

export interface QuestionPayloads {
  readonly asked: (
    questionId: string,
    questions: ReadonlyArray<QuestionSpec>,
    details?: QuestionDetails
  ) => QuestionAskedPayload
  readonly resolved: (
    questionId: string,
    questions: ReadonlyArray<QuestionSpec>,
    resolution: QuestionResolution
  ) => QuestionResolvedPayload
}

export const answersIfDefined: AnswersRule = (resolution) =>
  resolution.answers === undefined ? {} : { answers: resolution.answers }

export const answersIfPresent: AnswersRule = (resolution) =>
  "answers" in resolution && resolution.answers !== undefined ? { answers: resolution.answers } : {}

export const questionIdFirstPayloads = (answers: AnswersRule): QuestionPayloads => ({
  asked: (questionId, questions, details = {}) => ({
    questionId,
    questions,
    sessionUpdate: "question",
    ...presentDetails(details)
  }),
  resolved: (questionId, questions, resolution) => ({
    outcome: resolution.outcome,
    questionId,
    questions,
    sessionUpdate: "question_resolved",
    ...answers(resolution)
  })
})

export const sessionUpdateFirstPayloads = (answers: AnswersRule): QuestionPayloads => ({
  asked: (questionId, questions, details = {}) => ({
    sessionUpdate: "question",
    questionId,
    ...presentDetails(details),
    questions
  }),
  resolved: (questionId, questions, resolution) => ({
    sessionUpdate: "question_resolved",
    questionId,
    outcome: resolution.outcome,
    questions,
    ...answers(resolution)
  })
})

const presentDetails = (
  details: QuestionDetails
): Pick<QuestionAskedPayload, keyof QuestionDetails> => ({
  ...(details.message === undefined ? {} : { message: details.message }),
  ...(details.autoResolutionMs === undefined ? {} : { autoResolutionMs: details.autoResolutionMs })
})

export const questionReplyText = (reply: PromptInput): string | undefined => {
  const text = reply.text.trim()
  if (text.length === 0 || (reply.attachments?.length ?? 0) > 0) return undefined
  return `The user replied instead: ${text}`
}

export const SKIPPED_FOR_REPLY = "Skipped: the user's reply is in the first answer."

export const questionReplyAnswer = (index: number, reply: string): string =>
  index === 0 ? reply : SKIPPED_FOR_REPLY
