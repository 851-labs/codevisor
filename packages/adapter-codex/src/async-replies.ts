import type { QuestionAnswer } from "@codevisor/agent-runtime"
import type { QuestionAnswerEntry, QuestionSpec } from "@codevisor/api"

import type { CodexInputItem } from "./attachments.js"
import { answerCodexQuestion, dismissAsyncQuestion, emitQuestionResolved } from "./questions.js"
import type { CodexSession } from "./session.js"
import { completeNotificationTurn } from "./turn-notifications.js"
import { startCodexTurn } from "./turn-start.js"

export const answerQuestion = async (
  session: CodexSession,
  questionId: string,
  answer: QuestionAnswer
): Promise<void> => {
  const asked = session.asyncQuestion
  if (asked?.questionId !== questionId) return answerCodexQuestion(session, questionId, answer)
  const answers = answer.outcome === "answered" ? (answer.answers ?? {}) : {}
  const replies = asked.questions.flatMap((spec) => {
    const text = replyText(answers[spec.id])
    return text === undefined ? [] : [questionReply(spec, text)]
  })
  if (replies.length === 0) {
    const turnId = session.activeTurnId
    if (turnId !== undefined) {
      await steer(
        session,
        turnId,
        replyInput(asked.questions.map((spec) => questionReply(spec, DISMISSED)))
      )
    }
    dismissAsyncQuestion(session)
    if (session.heldTurnId !== undefined && session.activeTurnId === undefined) {
      completeNotificationTurn(session, { turn: { status: "completed" } })
    }
    return
  }
  await deliver(session, replyInput(replies))
  if (session.asyncQuestion === asked) session.asyncQuestion = undefined
  await emitQuestionResolved(session, questionId, "answered", asked.questions, answers)
}

const DISMISSED = "The user dismissed this question without answering."

const questionReply = (spec: QuestionSpec, answer: string) => ({
  answer,
  question: spec.question.slice(0, 512).replaceAll(/[\n\r]/g, " "),
  questionItemId: spec.id
})

const replyInput = (
  replies: ReadonlyArray<ReturnType<typeof questionReply>>
): Array<CodexInputItem> => [
  {
    text: `<send_user_message_question_reply>\n${JSON.stringify(replies)}\n</send_user_message_question_reply>`,
    type: "text"
  }
]

export const continueHeldTurn = async (
  session: CodexSession,
  input: ReadonlyArray<CodexInputItem>
): Promise<boolean> => {
  if (session.heldTurnId === undefined) return false
  dismissAsyncQuestion(session)
  await startCodexTurn(session, input)
  return true
}

export const cancelHeldTurn = (session: CodexSession): void => {
  if (session.heldTurnId === undefined) return
  completeNotificationTurn(session, { turn: { status: "interrupted" } })
}

const deliver = async (
  session: CodexSession,
  input: ReadonlyArray<CodexInputItem>
): Promise<void> => {
  const turnId = session.activeTurnId
  if (turnId !== undefined && (await steer(session, turnId, input))) return
  await startCodexTurn(session, input)
}

const steer = (
  session: CodexSession,
  turnId: string,
  input: ReadonlyArray<CodexInputItem>
): Promise<boolean> =>
  session.client
    .request("turn/steer", { expectedTurnId: turnId, input, threadId: session.threadId })
    .then(
      () => true,
      () => false
    )

const replyText = (entry: QuestionAnswerEntry | undefined): string | undefined => {
  if (entry === undefined) return undefined
  const note = entry.note?.trim() ?? ""
  const labels = entry.answers.join(", ")
  const text = labels.length > 0 ? (note.length > 0 ? `${labels} — ${note}` : labels) : note
  return text.length === 0 ? undefined : text
}
