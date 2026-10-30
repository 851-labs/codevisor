import { isPlanModeId, type QuestionAnswer, type QuestionOutcome } from "@codevisor/agent-runtime"
import type { QuestionPayload, SessionModeState } from "@codevisor/api"
import { isAgentQuestion } from "@codevisor/db"

import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

export const pendingAgentQuestion = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<QuestionPayload | undefined> => {
  const question = await run(services.db.getSessionPendingQuestion(sessionId))
  return question !== undefined && isAgentQuestion(question) ? question : undefined
}

export const resolveParkedQuestion = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  question: QuestionPayload,
  resolution: { readonly outcome: QuestionOutcome; readonly answers?: QuestionAnswer["answers"] }
): Promise<void> => {
  await appendAndPublish(services.db, fanout, "session.output", sessionId, {
    sessionUpdate: "question_resolved",
    questionId: question.questionId,
    questions: question.questions,
    outcome: resolution.outcome,
    ...(resolution.answers === undefined ? {} : { answers: resolution.answers }),
    serverId
  })
}

export const heldByParkedQuestion = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string
): Promise<boolean> => {
  const question = await pendingAgentQuestion(services, sessionId)
  if (question === undefined) return false

  const queue = await run(services.db.listPromptQueue(sessionId))
  if (queue.every((item) => item.origin === "system")) return true

  await resolveParkedQuestion(services, fanout, serverId, sessionId, question, {
    outcome: "replied"
  })
  return false
}

export const parkedAnswerPrompt = (question: QuestionPayload, answer: QuestionAnswer): string =>
  [
    `<codevisor-event type="question.answered">`,
    "Codevisor restarted while you were waiting on your question, so the tool call that asked it ended without the user's answer.",
    ...answerSummary(question, answer),
    "Continue from where you left off.",
    "</codevisor-event>"
  ].join("\n")

export const leavesPlanMode = (question: QuestionPayload, answer: QuestionAnswer): boolean =>
  planDecision(question, answer) !== undefined

export const buildModeId = (modes: SessionModeState | undefined): string | undefined => {
  const current = modes?.availableModes.find((mode) => mode.id === modes.currentModeId)
  if (current === undefined || !isPlanMode(current)) return undefined
  const available = modes!.availableModes
  return (
    available.find((mode) => mode.canonicalId === "fullAccess") ??
    available.find((mode) => !isPlanMode(mode))
  )?.id
}

const planApprovalIds: ReadonlySet<string> = new Set(["exit_plan_mode", "grok_exit_plan_mode"])

const planDecision = (
  question: QuestionPayload,
  answer: QuestionAnswer
): "implement" | "abandon" | undefined => {
  if (answer.outcome !== "answered") return undefined
  const spec = question.questions.find((candidate) => planApprovalIds.has(candidate.id))
  const choice = spec === undefined ? undefined : answer.answers?.[spec.id]?.answers[0]
  if (choice === "Implement plan") return "implement"
  if (choice === "Abandon plan") return "abandon"
  return undefined
}

const isPlanMode = (mode: SessionModeState["availableModes"][number]): boolean =>
  mode.canonicalId === "plan" || isPlanModeId(mode.id)

const answerSummary = (
  question: QuestionPayload,
  answer: QuestionAnswer
): ReadonlyArray<string> => {
  if (answer.outcome !== "answered") return ["The user has now dismissed it without answering."]
  const decision = planDecision(question, answer)
  if (decision === "implement") {
    return [
      "The user approved your plan and plan mode is now off. Implement the plan without asking for approval again."
    ]
  }
  if (decision === "abandon") {
    return ["The user chose to leave plan mode without implementing the plan."]
  }
  return ["The user has now answered it:", ...answerLines(question, answer)]
}

const answerLines = (question: QuestionPayload, answer: QuestionAnswer): ReadonlyArray<string> =>
  question.questions.map((spec) => {
    const entry = answer.answers?.[spec.id]
    const labels = entry?.answers.join(", ") ?? ""
    const note = entry?.note?.trim() ?? ""
    const value = [labels, note].filter((part) => part.length > 0).join(" — ")
    return `- ${spec.question} → ${value.length > 0 ? value : "(no answer)"}`
  })
