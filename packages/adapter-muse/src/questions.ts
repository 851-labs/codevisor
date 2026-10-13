import type { QuestionAnswer } from "@codevisor/agent-runtime"
import type { QuestionSpec } from "@codevisor/api"

import { commandId, text, type ApprovalRequest, type UserInputRequest } from "./protocol.js"

/// Muse's blocking asks as Codevisor questions. Both arrive as server
/// requests acknowledged with an empty receipt; the answer is a separate
/// command (`approval/decide`, `userInput/answer` or `userInput/cancel`).

export interface MuseQuestion {
  readonly specs: ReadonlyArray<QuestionSpec>
  readonly autoResolutionMs?: number
  /// The command that delivers the user's answer to Muse.
  readonly reply: (answer: QuestionAnswer) => { method: string; params: Record<string, unknown> }
}

const PERMISSION_ID = "permission"

/// Muse ships Codevisor's sessions in `allowAll`, so only escalations its
/// reviewer can't settle arrive here — answered with Muse's own choices.
export const approvalQuestion = (request: ApprovalRequest): MuseQuestion => {
  const subject = text(request.subject.command) ?? text(request.subject.path)
  // Dismissing refuses: Muse's abort, else a denial, else any choice that
  // doesn't approve. With none of those, the turn itself is stopped.
  const refusal =
    request.availableChoices.find((choice) => choice.decision === "abort") ??
    request.availableChoices.find((choice) => choice.decision.startsWith("denied")) ??
    request.availableChoices.find((choice) => !choice.decision.startsWith("approved"))
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
    reply: (answer) => {
      const chosen =
        answer.outcome === "answered"
          ? request.availableChoices.find(
              (choice) => choice.label === answer.answers?.[PERMISSION_ID]?.answers[0]
            )
          : undefined
      const choice = chosen ?? refusal
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
  }
}

/// `request_user_input`: one or more questions with labelled options; any
/// answer can also be free text.
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
    const base = {
      commandId: commandId(),
      sessionId: request.sessionId,
      userInputId: request.userInputId
    }
    if (answer.outcome !== "answered")
      return {
        method: "userInput/cancel",
        params: { ...base, reason: "The user dismissed the question." }
      }
    return {
      method: "userInput/answer",
      params: {
        ...base,
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
  }
})
