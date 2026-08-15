import { randomUUID } from "node:crypto"
import type { QuestionSpec } from "@codevisor/api"
import type { QuestionAnswer } from "@codevisor/agent-runtime"
import { isRecord } from "./internal.js"
import type { ClaudeSession, ClaudeToolDecision } from "./session.js"
import { toolTitle } from "./tool-presentation.js"

// MARK: questions

/// Emits the AskUserQuestion as a blocking `question` event and holds the
/// SDK's canUseTool promise open until the human answers. Malformed input
/// falls back to auto-allow so an SDK shape drift can't wedge the turn.
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

/// Lenient mapping from AskUserQuestion input to the wire QuestionSpec.
/// Ids are positional (`question_<n>`) — the answers map keys back by index.
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

/// Folds the human's answer back into the tool input the way the SDK's
/// AskUserQuestion expects: `answers` keyed by the QUESTION TEXT, valued with
/// the chosen label(s). A note supplements a selection (appended after an
/// em-dash) and stands alone as the answer when nothing was selected (the
/// "Other" path). Cancel denies the tool so the model knows the user
/// dismissed the question.
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

/// Surfaces a tool-permission check as a blocking Allow/Deny question. Only
/// reached when the CLI's permission mode requires asking (Ask/Plan modes);
/// the bypassPermissions default never invokes canUseTool.
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

/// The stable question id + option labels that tag Claude's ExitPlanMode
/// approval, so clients recognize a plan approval and answer it. Kept in sync
/// with the Swift client (ACPKit `QuestionRequest`).
const EXIT_PLAN_MODE_QUESTION_ID = "exit_plan_mode"
const IMPLEMENT_PLAN_LABEL = "Implement plan"
const KEEP_PLANNING_LABEL = "Keep planning"

/// ExitPlanMode's approval as a dedicated plan-approval question: the client
/// renders an "implement this plan?" affordance (the plan markdown itself rides
/// a separate `plan_document` update — see emitPlanUpdate). Approving lets the
/// tool through so the model starts implementing; declining keeps it in plan
/// mode, and the deny message nudges it to keep refining rather than stop.
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
      respond: (answer) =>
        answer.outcome === "answered" &&
        answer.answers?.[spec.id]?.answers[0] === IMPLEMENT_PLAN_LABEL
          ? { behavior: "allow", updatedInput: toolInput }
          : {
              behavior: "deny",
              message:
                "The user wants to keep refining the plan. Stay in plan mode and continue planning."
            }
    })
  })
}

/// Interrupts, turn results, and session close invalidate held questions:
/// deny them (the model sees a dismissal) and emit the resolution so clients
/// drop the picker.
export const cancelClaudePendingQuestions = (session: ClaudeSession): Promise<void> => {
  const emissions: Array<Promise<void>> = []
  for (const [questionId, pending] of [...session.pendingQuestions]) {
    session.pendingQuestions.delete(questionId)
    pending.resolve(pending.respond({ outcome: "cancelled" }))
    emissions.push(
      emitClaudeQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
    )
  }
  return Promise.all(emissions).then(() => undefined)
}
