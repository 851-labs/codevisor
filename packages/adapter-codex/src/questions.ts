import { randomUUID } from "node:crypto"

import {
  answersIfDefined,
  questionIdFirstPayloads,
  type QuestionAnswer,
  type QuestionOutcome
} from "@codevisor/agent-runtime"
import type { QuestionSpec } from "@codevisor/api"

import { elicitationFields } from "./elicitation-schema.js"
import { isRecord } from "./internal.js"
import type { CodexSession, PendingCodexQuestion } from "./session.js"

const questionPayloads = questionIdFirstPayloads(answersIfDefined)

export const serverRequestResponse = (
  session: CodexSession,
  method: string,
  params: unknown,
  signal: AbortSignal
): Promise<unknown> => {
  switch (method) {
    case "item/tool/requestUserInput":
      return holdQuestionRequest(session, isRecord(params) ? params : {}, signal)
    case "mcpServer/elicitation/request":
      return holdElicitationRequest(session, isRecord(params) ? params : {}, signal)
    case "item/commandExecution/requestApproval":
    case "item/fileChange/requestApproval":
    case "item/permissions/requestApproval":
      return holdApprovalRequest(session, method, isRecord(params) ? params : {}, signal)
    default:
      return Promise.reject(new Error(`Unsupported approval request: ${method}`))
  }
}

const dismissQuestionOnAbort = (
  session: CodexSession,
  questionId: string,
  signal: AbortSignal
): void => {
  signal.addEventListener(
    "abort",
    () => {
      const pending = session.pendingQuestions.get(questionId)
      if (pending === undefined) return
      session.pendingQuestions.delete(questionId)
      if (pending.timer !== undefined) clearTimeout(pending.timer)
      dismissPendingQuestion(pending, "Question cancelled: codex connection closed")
      void emitQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
    },
    { once: true }
  )
}

const approvalQuestion = (method: string, isCommand: boolean): string => {
  if (method === "item/fileChange/requestApproval") return "Allow these file edits?"
  if (isCommand) return "Allow this command to run?"
  return "Grant the requested permissions?"
}

const approvalDecision = (label: string | undefined) => {
  if (label === "Allow") return "accept"
  if (label === "Allow for session") return "acceptForSession"
  return "decline"
}

const holdApprovalRequest = (
  session: CodexSession,
  method: string,
  params: Record<string, unknown>,
  signal: AbortSignal
): Promise<unknown> => {
  const itemId = typeof params.itemId === "string" ? params.itemId : undefined
  const detail = itemId === undefined ? undefined : session.itemTitles.get(itemId)
  const isCommand = method === "item/commandExecution/requestApproval"
  const spec: QuestionSpec = {
    allowsOther: false,
    id: "approval",
    options: [
      { label: "Allow" },
      ...(isCommand ? [{ label: "Allow for session" }] : []),
      { label: "Deny" }
    ],
    question: approvalQuestion(method, isCommand),
    ...(isCommand ? { header: "Command" } : {}),
    ...(method === "item/fileChange/requestApproval" ? { header: "Edits" } : {}),
    ...(method === "item/permissions/requestApproval" ? { header: "Permissions" } : {})
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: questionPayloads.asked(questionId, [spec], { message: detail }),
    subjectId: session.key
  })
  return new Promise<unknown>((resolve, reject) => {
    session.pendingQuestions.set(questionId, {
      cancelResponse: { decision: "cancel" },
      questions: [spec],
      reject,
      resolve,
      respond: (answers) => {
        const label = answers[spec.id]?.answers[0]
        const decision = approvalDecision(label)
        return { decision }
      },
      timer: undefined
    })
    dismissQuestionOnAbort(session, questionId, signal)
  })
}

const holdQuestionRequest = (
  session: CodexSession,
  params: Record<string, unknown>,
  signal: AbortSignal
): Promise<unknown> => {
  const questionId = typeof params.itemId === "string" ? params.itemId : randomUUID()
  const questions = questionSpecsFrom(params.questions)
  if (questions.length === 0) {
    return Promise.reject(new Error("requestUserInput carried no questions"))
  }
  const autoResolutionMs =
    typeof params.autoResolutionMs === "number" ? params.autoResolutionMs : undefined
  void session.emit({
    kind: "session.output",
    payload: questionPayloads.asked(questionId, questions, { autoResolutionMs }),
    subjectId: session.key
  })
  return new Promise<unknown>((resolve, reject) => {
    const timer = scheduleAutoResolutionIfRequested(
      session,
      questionId,
      questions,
      autoResolutionMs
    )
    timer?.unref?.()
    session.pendingQuestions.set(questionId, {
      questions,
      reject,
      resolve,
      respond: (answers) => ({
        answers: Object.fromEntries(
          Object.entries(answers).map(([id, entry]) => [
            id,
            {
              answers: [
                ...entry.answers,
                ...(entry.note === undefined || entry.note.length === 0
                  ? []
                  : [`user_note: ${entry.note}`])
              ]
            }
          ])
        )
      }),
      timer
    })
    dismissQuestionOnAbort(session, questionId, signal)
  })
}

const scheduleAutoResolutionIfRequested = (
  session: CodexSession,
  questionId: string,
  questions: ReadonlyArray<QuestionSpec>,
  autoResolutionMs: number | undefined
): ReturnType<typeof setTimeout> | undefined => {
  if (autoResolutionMs === undefined) return undefined
  return setTimeout(() => {
    const pending = session.pendingQuestions.get(questionId)
    if (pending === undefined) return
    session.pendingQuestions.delete(questionId)
    pending.resolve({ answers: {} })
    void emitQuestionResolved(session, questionId, "autoResolved", questions, undefined)
  }, autoResolutionMs)
}

const holdElicitationRequest = (
  session: CodexSession,
  params: Record<string, unknown>,
  signal: AbortSignal
): Promise<unknown> => {
  const schema = isRecord(params.requestedSchema) ? params.requestedSchema : undefined
  const fields = schema !== undefined ? elicitationFields(schema) : []
  if (params.mode === "url" || fields.length === 0) {
    return Promise.resolve({ action: "decline", content: null })
  }
  const questionId = randomUUID()
  const serverName = typeof params.serverName === "string" ? params.serverName : "MCP server"
  const message = typeof params.message === "string" ? params.message : undefined
  const questions = fields.map((field) => field.spec)
  void session.emit({
    kind: "session.output",
    payload: {
      message: message ?? `${serverName} needs input to continue.`,
      ...questionPayloads.asked(questionId, questions)
    },
    subjectId: session.key
  })
  return new Promise<unknown>((resolve, reject) => {
    session.pendingQuestions.set(questionId, {
      cancelResponse: { action: "cancel", content: null },
      questions,
      reject,
      resolve,
      respond: (answers) => {
        const content: Record<string, unknown> = {}
        for (const field of fields) {
          const entry = answers[field.spec.id]
          if (entry === undefined) continue
          const value = field.coerce(entry)
          if (value !== undefined) {
            content[field.spec.id] = value
          }
        }
        return { action: "accept", content }
      },
      timer: undefined
    })
    dismissQuestionOnAbort(session, questionId, signal)
  })
}

const questionSpecsFrom = (value: unknown): Array<QuestionSpec> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
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
        allowsOther: entry.isOther !== false,
        id: typeof entry.id === "string" ? entry.id : randomUUID(),
        options,
        question: entry.question,
        ...(typeof entry.header === "string" ? { header: entry.header } : {}),
        ...(entry.isSecret === true ? { isSecret: true } : {})
      }
    ]
  })
}

export const askAsyncQuestions = (session: CodexSession, itemId: string, value: unknown): void => {
  const asked = asyncQuestionSpecsFrom(itemId, value)
  if (asked.length === 0) return
  const questionId = session.asyncQuestion?.questionId ?? itemId
  const questions = [...(session.asyncQuestion?.questions ?? []), ...asked]
  session.asyncQuestion = { questionId, questions }
  void session.emit({
    kind: "session.output",
    payload: questionPayloads.asked(questionId, questions),
    subjectId: session.key
  })
}

const asyncQuestionSpecsFrom = (itemId: string, value: unknown): Array<QuestionSpec> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry: unknown, index) => {
    if (!isRecord(entry) || typeof entry.title !== "string" || entry.title.trim().length === 0) {
      return []
    }
    const options = Array.isArray(entry.options)
      ? entry.options.flatMap((option: unknown) =>
          typeof option === "string" && option.trim().length > 0 ? [{ label: option }] : []
        )
      : []
    return [
      {
        allowsOther: true,
        id: JSON.stringify(["request_user_input_async", itemId, index]),
        options,
        question: entry.title
      }
    ]
  })
}

export const emitQuestionResolved = (
  session: CodexSession,
  questionId: string,
  outcome: QuestionOutcome,
  questions: ReadonlyArray<QuestionSpec>,
  answers: QuestionAnswer["answers"]
): Promise<void> =>
  session.emit({
    kind: "session.output",
    payload: questionPayloads.resolved(questionId, questions, { outcome, answers }),
    subjectId: session.key
  })

export const answerCodexQuestion = async (
  session: CodexSession,
  questionId: string,
  answer: QuestionAnswer
): Promise<void> => {
  const pending = session.pendingQuestions.get(questionId)
  if (pending === undefined) {
    throw new Error(`No pending question: ${questionId}`)
  }
  session.pendingQuestions.delete(questionId)
  if (pending.timer !== undefined) clearTimeout(pending.timer)
  if (answer.outcome === "cancelled") {
    dismissPendingQuestion(pending, "User dismissed the question without answering")
    await emitQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
    return
  }
  const answers = answer.answers ?? {}
  pending.resolve(pending.respond(answers))
  await emitQuestionResolved(session, questionId, "answered", pending.questions, answers)
}

const dismissPendingQuestion = (pending: PendingCodexQuestion, reason: string): void => {
  if (pending.cancelResponse !== undefined) {
    pending.resolve(pending.cancelResponse)
  } else {
    pending.reject(new Error(reason))
  }
}

export const cancelPendingQuestions = (session: CodexSession): void => {
  dismissAsyncQuestion(session)
  for (const [questionId, pending] of Array.from(session.pendingQuestions)) {
    session.pendingQuestions.delete(questionId)
    if (pending.timer !== undefined) clearTimeout(pending.timer)
    dismissPendingQuestion(pending, "Question cancelled with the turn")
    void emitQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
  }
}

export const dismissAsyncQuestion = (session: CodexSession): void => {
  const asked = session.asyncQuestion
  if (asked === undefined) return
  session.asyncQuestion = undefined
  void emitQuestionResolved(session, asked.questionId, "cancelled", asked.questions, undefined)
}
