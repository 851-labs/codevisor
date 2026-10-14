import { randomUUID } from "node:crypto"

import type { QuestionAnswer } from "@codevisor/agent-runtime"
import type { QuestionSpec } from "@codevisor/api"

import { isRecord } from "./internal.js"
import type { ClaudeSession, ClaudeToolDecision } from "./session.js"
import { toolTitle } from "./tool-presentation.js"

export const holdClaudeQuestion = (
  session: ClaudeSession,
  toolInput: Record<string, unknown>
): Promise<ClaudeToolDecision> => {
  const questions = claudeQuestionSpecs(toolInput.questions)
  if (questions.length === 0) {
    return Promise.resolve({ behavior: "allow", updatedInput: toolInput })
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: { questionId, questions, sessionUpdate: "question" },
    subjectId: session.key
  })
  return new Promise((resolve) => {
    session.pendingQuestions.set(questionId, {
      questions,
      resolve,
      respond: (answer) => {
        if (answer.outcome === "cancelled") {
          return { behavior: "deny", message: "User dismissed the question without answering." }
        }
        const entries = answer.answers ?? {}
        const answers: Record<string, string> = {}
        for (const spec of questions) {
          const entry = entries[spec.id]
          if (entry === undefined) continue
          const note = entry.note?.trim() ?? ""
          const labels = entry.answers.join(", ")
          const value =
            labels.length > 0 ? (note.length > 0 ? `${labels} — ${note}` : labels) : note
          if (value.length > 0) {
            answers[spec.question] = value
          }
        }
        return { behavior: "allow", updatedInput: { ...toolInput, answers } }
      }
    })
  })
}

const claudeQuestionSpecs = (value: unknown): Array<QuestionSpec> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry, index) => {
    if (!isRecord(entry) || typeof entry.question !== "string") return []
    const options = Array.isArray(entry.options)
      ? entry.options.flatMap((option) =>
          isRecord(option) && typeof option.label === "string"
            ? [
                {
                  label: option.label,
                  ...(typeof option.description === "string"
                    ? { description: option.description }
                    : {})
                }
              ]
            : []
        )
      : []
    return [
      {
        allowsOther: true,
        id: `question_${index}`,
        options,
        question: entry.question,
        ...(typeof entry.header === "string" ? { header: entry.header } : {}),
        ...(entry.multiSelect === true ? { multiSelect: true } : {})
      }
    ]
  })
}

export const answerClaudeQuestion = async (
  session: ClaudeSession,
  questionId: string,
  answer: QuestionAnswer
): Promise<void> => {
  const pending = session.pendingQuestions.get(questionId)
  if (pending === undefined) {
    throw new Error(`No pending question: ${questionId}`)
  }
  session.pendingQuestions.delete(questionId)
  pending.resolve(pending.respond(answer))
  await emitClaudeQuestionResolved(
    session,
    questionId,
    answer.outcome === "answered" ? "answered" : "cancelled",
    pending.questions,
    answer.outcome === "answered" ? answer.answers : undefined
  )
}

const emitClaudeQuestionResolved = (
  session: ClaudeSession,
  questionId: string,
  outcome: "answered" | "cancelled",
  questions: ReadonlyArray<QuestionSpec>,
  answers: QuestionAnswer["answers"]
): Promise<void> =>
  session.emit({
    kind: "session.output",
    payload: {
      outcome,
      questionId,
      questions,
      sessionUpdate: "question_resolved",
      ...(answers === undefined ? {} : { answers })
    },
    subjectId: session.key
  })

export const holdClaudeApproval = (
  session: ClaudeSession,
  toolName: string,
  toolInput: Record<string, unknown>
): Promise<ClaudeToolDecision> => {
  const spec: QuestionSpec = {
    allowsOther: false,
    header: "Permission",
    id: "approval",
    options: [{ label: "Allow" }, { label: "Deny" }],
    question: `Allow ${toolName}?`
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: {
      message: toolTitle(toolName, toolInput),
      questionId,
      questions: [spec],
      sessionUpdate: "question"
    },
    subjectId: session.key
  })
  return new Promise((resolve) => {
    session.pendingQuestions.set(questionId, {
      questions: [spec],
      resolve,
      respond: (answer) =>
        answer.outcome === "answered" && answer.answers?.[spec.id]?.answers[0] === "Allow"
          ? { behavior: "allow", updatedInput: toolInput }
          : { behavior: "deny", message: "User denied permission." }
    })
  })
}

const EXIT_PLAN_MODE_QUESTION_ID = "exit_plan_mode"
const IMPLEMENT_PLAN_LABEL = "Implement plan"
const KEEP_PLANNING_LABEL = "Keep planning"
const KEEP_PLANNING_MESSAGE =
  "The user wants to keep refining the plan. Stay in plan mode and continue planning."

export const holdClaudePlanApproval = (
  session: ClaudeSession,
  toolInput: Record<string, unknown>
): Promise<ClaudeToolDecision> => {
  const spec: QuestionSpec = {
    allowsOther: false,
    header: "Plan",
    id: EXIT_PLAN_MODE_QUESTION_ID,
    options: [
      { description: "Start building", label: IMPLEMENT_PLAN_LABEL },
      { description: "Keep refining in plan mode", label: KEEP_PLANNING_LABEL }
    ],
    question: "Ready to implement this plan?"
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: { questionId, questions: [spec], sessionUpdate: "question" },
    subjectId: session.key
  })
  return new Promise((resolve) => {
    session.pendingQuestions.set(questionId, {
      questions: [spec],
      resolve,
      respond: (answer) => {
        const entry = answer.outcome === "answered" ? answer.answers?.[spec.id] : undefined
        if (entry?.answers[0] === IMPLEMENT_PLAN_LABEL) {
          return { behavior: "allow", updatedInput: toolInput }
        }
        const feedback = entry?.note?.trim()
        return {
          behavior: "deny",
          message:
            feedback === undefined || feedback === ""
              ? KEEP_PLANNING_MESSAGE
              : `${KEEP_PLANNING_MESSAGE}\n\nThe user's feedback on the plan:\n${feedback}`
        }
      }
    })
  })
}

export const cancelClaudePendingQuestions = (session: ClaudeSession): Promise<void> => {
  const emissions: Array<Promise<void>> = []
  for (const [questionId, pending] of Array.from(session.pendingQuestions)) {
    session.pendingQuestions.delete(questionId)
    pending.resolve(pending.respond({ outcome: "cancelled" }))
    emissions.push(
      emitClaudeQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
    )
  }
  return Promise.all(emissions).then(() => undefined)
}
