import type {
  QuestionOutcome,
  QuestionPresentation,
  TranscriptQuestionInteraction
} from "@codevisor/api"
import { QuestionAnswerEntry, QuestionSpec } from "@codevisor/api"
import { Schema } from "effect"

import { payloadRows } from "./common-rows.js"
import { parseJsonRecord, type JsonRecord } from "./event-payloads.js"
import type { ServiceContext } from "./service-context.js"
import { setupQuestionPresentation } from "./setup-questions.js"
import { asksInTranscript } from "./transcript-questions.js"

export interface SetupRequestSummary {
  readonly questionId: string
  readonly presentation: QuestionPresentation
  readonly outcome?: QuestionOutcome
}

export interface ItemQuestionSummaries {
  readonly setupRequests: ReadonlyArray<SetupRequestSummary>
  readonly interactions: ReadonlyArray<TranscriptQuestionInteraction>
}

export const itemQuestionSummaries = (
  sqlite: ServiceContext["sqlite"],
  itemId: string,
  pendingQuestionId: string | undefined
): ItemQuestionSummaries => {
  const payloads = questionEntryPayloads(sqlite, itemId)
  return {
    setupRequests: latestSetupRequests(payloads).map((request) =>
      withAbandonedOutcome(request, pendingQuestionId)
    ),
    interactions: questionInteractions(payloads).map((interaction) =>
      withAbandonedAnswer(interaction, pendingQuestionId)
    )
  }
}

const questionOutcomes: ReadonlySet<unknown> = new Set<QuestionOutcome>([
  "answered",
  "cancelled",
  "autoResolved",
  "replied"
])

const isQuestionOutcome = (value: unknown): value is QuestionOutcome => questionOutcomes.has(value)

const isQuestionSpecs = Schema.is(Schema.Array(QuestionSpec))

const isQuestionAnswers = Schema.is(Schema.Record(Schema.String, QuestionAnswerEntry))

const questionEntryPayloads = (
  sqlite: ServiceContext["sqlite"],
  itemId: string
): ReadonlyArray<JsonRecord | undefined> =>
  payloadRows
    .all(sqlite.prepare(questionEntriesSql).all(itemId))
    .map((row) => parseJsonRecord(row.payload))

const latestSetupRequests = (
  payloads: ReadonlyArray<JsonRecord | undefined>
): ReadonlyArray<SetupRequestSummary> => {
  const byQuestion = new Map<string, SetupRequestSummary>()
  for (const payload of payloads) {
    const request = setupRequestSummary(payload)
    if (request !== undefined) byQuestion.set(request.questionId, request)
  }
  return [...byQuestion.values()]
}

const setupRequestSummary = (payload: JsonRecord | undefined): SetupRequestSummary | undefined => {
  const questionId = payload?.questionId
  const presentation = setupQuestionPresentation(payload)
  if (typeof questionId !== "string" || presentation === undefined) return undefined

  if (!isQuestionOutcome(payload?.outcome)) return { questionId, presentation }
  return { questionId, presentation, outcome: payload.outcome }
}

const withAbandonedOutcome = (
  request: SetupRequestSummary,
  pendingQuestionId: string | undefined
): SetupRequestSummary => {
  if (request.outcome !== undefined || request.questionId === pendingQuestionId) return request
  return { ...request, outcome: "cancelled" }
}

const questionInteractions = (
  payloads: ReadonlyArray<JsonRecord | undefined>
): ReadonlyArray<TranscriptQuestionInteraction> => {
  const byQuestion = new Map<string, TranscriptQuestionInteraction>()
  for (const payload of payloads) {
    const interaction = questionInteraction(payload, byQuestion)
    if (interaction !== undefined) byQuestion.set(interaction.id, interaction)
  }
  return [...byQuestion.values()]
}

const questionInteraction = (
  payload: JsonRecord | undefined,
  known: ReadonlyMap<string, TranscriptQuestionInteraction>
): TranscriptQuestionInteraction | undefined => {
  const id = payload?.questionId
  if (typeof id !== "string" || !asksInTranscript(payload)) return undefined

  const asked = known.get(id) ?? askedInteraction(id, payload)
  if (asked === undefined || !isQuestionOutcome(payload?.outcome)) return asked
  return { ...asked, answer: questionAnswer(payload.outcome, payload?.answers) }
}

const askedInteraction = (
  id: string,
  payload: JsonRecord | undefined
): TranscriptQuestionInteraction | undefined => {
  const questions = payload?.questions
  if (!isQuestionSpecs(questions)) return undefined

  const message = typeof payload?.message === "string" ? { message: payload.message } : {}
  return { id, kind: "question", payload: { ...message, questions } }
}

const questionAnswer = (
  outcome: QuestionOutcome,
  answers: unknown
): NonNullable<TranscriptQuestionInteraction["answer"]> => {
  if (!isQuestionAnswers(answers)) return { outcome }
  return { outcome, answers }
}

const withAbandonedAnswer = (
  interaction: TranscriptQuestionInteraction,
  pendingQuestionId: string | undefined
): TranscriptQuestionInteraction => {
  if (interaction.answer !== undefined || interaction.id === pendingQuestionId) return interaction
  return { ...interaction, answer: { outcome: "cancelled" } }
}

const questionEntriesSql =
  "select payload from transcript_entries where item_id = ? and category = 'question' order by position"
