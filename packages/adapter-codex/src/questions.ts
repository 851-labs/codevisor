import type { QuestionAnswerEntry, QuestionSpec } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import type { QuestionAnswer } from "@codevisor/agent-runtime"
import { isRecord } from "./internal.js"
import type { CodexSession, PendingCodexQuestion } from "./session.js"

/// Routes codex's server→client requests: questions, MCP elicitations, and
/// approvals block on the human's answer. The signal aborts when the codex
/// connection dies with the ask still open — the process that would receive
/// the answer is gone, so the ask is retracted instead of held forever.
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
      // Approvals only arrive in modes with approvalPolicy on-request (Agent /
      // Read-only). Full-access and Plan modes never ask.
      return holdApprovalRequest(session, method, isRecord(params) ? params : {}, signal)
    default:
      return Promise.reject(new Error(`Unsupported approval request: ${method}`))
  }
}

/// Connection death retracts a held ask: settle the JSON-RPC promise via
/// the source-specific dismissal and emit the resolution so clients drop
/// the picker. Idempotent with the other cancellation paths (turn
/// interrupt/completion, session close) — whichever runs first removes the
/// map entry, and the rest find nothing to do.
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

/// Surfaces a codex approval request as a blocking question: Allow/Deny (plus
/// "Allow for session" on commands) mapping onto the wire decisions. Cancel
/// and turn interrupts answer `cancel`.
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
    question:
      method === "item/fileChange/requestApproval"
        ? "Allow these file edits?"
        : isCommand
          ? "Allow this command to run?"
          : "Grant the requested permissions?",
    ...(isCommand ? { header: "Command" } : {}),
    ...(method === "item/fileChange/requestApproval" ? { header: "Edits" } : {}),
    ...(method === "item/permissions/requestApproval" ? { header: "Permissions" } : {})
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: {
      questionId,
      questions: [spec],
      sessionUpdate: "question",
      ...(detail === undefined ? {} : { message: detail })
    },
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
        const decision =
          label === "Allow"
            ? "accept"
            : label === "Allow for session"
              ? "acceptForSession"
              : "decline"
        return { decision }
      },
      timer: undefined
    })
    dismissQuestionOnAbort(session, questionId, signal)
  })
}

// MARK: questions

/// Emits the question to the client and holds codex's JSON-RPC request open
/// until the human answers (or the auto-resolution window elapses — codex
/// marks such asks non-blocking, so we mirror its TUI and submit empty
/// answers to let the turn continue).
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
    payload: {
      questionId,
      questions,
      sessionUpdate: "question",
      ...(autoResolutionMs === undefined ? {} : { autoResolutionMs })
    },
    subjectId: session.key
  })
  return new Promise<unknown>((resolve, reject) => {
    const timer =
      autoResolutionMs === undefined
        ? undefined
        : setTimeout(() => {
            const pending = session.pendingQuestions.get(questionId)
            if (pending === undefined) return
            session.pendingQuestions.delete(questionId)
            pending.resolve({ answers: {} })
            void emitQuestionResolved(session, questionId, "autoResolved", questions, undefined)
          }, autoResolutionMs)
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

/// Emits an MCP server's elicitation as a question and holds the request
/// open. Form fields map onto question specs (enums → options, booleans →
/// Yes/No, string/number → free text); the reply is the structured
/// `{action, content}` MCP expects, with values coerced back to field types.
/// URL-mode elicitations are declined — there is no browser hand-off UX yet.
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
      questionId,
      questions,
      sessionUpdate: "question"
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

interface ElicitationField {
  readonly spec: QuestionSpec
  /// Coerces the wire answer entry back to the field's schema type; undefined
  /// drops the field from the accepted content.
  readonly coerce: (entry: QuestionAnswerEntry) => unknown
}

/// Lenient flat-object mapping of the MCP elicitation form schema
/// (2025-11-25 `ElicitRequestFormParams`) onto question specs.
const elicitationFields = (schema: Record<string, unknown>): Array<ElicitationField> => {
  if (!isRecord(schema.properties)) return []
  return Object.entries(schema.properties).flatMap(([key, raw]): Array<ElicitationField> => {
    if (!isRecord(raw)) return []
    const title = typeof raw.title === "string" ? raw.title : undefined
    const description = typeof raw.description === "string" ? raw.description : undefined
    const question = description ?? title ?? key
    const base = { id: key, question }

    // Single-select enums: `oneOf: [{const, title}]` or `enum` (+ enumNames).
    const constOptions = Array.isArray(raw.oneOf) ? enumOptions(raw.oneOf) : undefined
    const plainEnum = Array.isArray(raw.enum)
      ? plainEnumOptions(raw.enum, raw.enumNames)
      : undefined
    if (constOptions !== undefined || plainEnum !== undefined) {
      const options = constOptions ?? plainEnum ?? []
      return [
        {
          coerce: (entry) => options.find((option) => option.label === entry.answers[0])?.value,
          spec: { ...base, allowsOther: false, options: options.map(optionSpec) }
        }
      ]
    }
    // Multi-select enums: `type: "array"` with enum-shaped `items`.
    if (raw.type === "array" && isRecord(raw.items)) {
      const items = raw.items
      const options =
        (Array.isArray(items.anyOf) ? enumOptions(items.anyOf) : undefined) ??
        (Array.isArray(items.oneOf) ? enumOptions(items.oneOf) : undefined) ??
        (Array.isArray(items.enum) ? plainEnumOptions(items.enum, items.enumNames) : undefined) ??
        []
      if (options.length === 0) return []
      return [
        {
          coerce: (entry) =>
            entry.answers.flatMap((label) => {
              const value = options.find((option) => option.label === label)?.value
              return value === undefined ? [] : [value]
            }),
          spec: { ...base, allowsOther: false, multiSelect: true, options: options.map(optionSpec) }
        }
      ]
    }
    if (raw.type === "boolean") {
      return [
        {
          coerce: (entry) =>
            entry.answers[0] === "Yes" ? true : entry.answers[0] === "No" ? false : undefined,
          spec: {
            ...base,
            allowsOther: false,
            options: [{ label: "Yes" }, { label: "No" }]
          }
        }
      ]
    }
    if (raw.type === "number" || raw.type === "integer") {
      return [
        {
          coerce: (entry) => {
            const text = entry.note ?? entry.answers[0] ?? ""
            const parsed = Number(text)
            return Number.isFinite(parsed) ? parsed : undefined
          },
          spec: { ...base, allowsOther: true, options: [] }
        }
      ]
    }
    // Strings (and anything unrecognized) become free-text questions.
    return [
      {
        coerce: (entry) => {
          const text = (entry.note ?? entry.answers[0] ?? "").trim()
          return text.length > 0 ? text : undefined
        },
        spec: { ...base, allowsOther: true, options: [] }
      }
    ]
  })
}

interface LabeledValue {
  readonly label: string
  readonly description?: string
  readonly value: string
}

const enumOptions = (entries: ReadonlyArray<unknown>): Array<LabeledValue> | undefined => {
  const options = entries.flatMap((entry) =>
    isRecord(entry) && typeof entry.const === "string"
      ? [
          {
            label: typeof entry.title === "string" ? entry.title : entry.const,
            value: entry.const
          }
        ]
      : []
  )
  return options.length > 0 ? options : undefined
}

const plainEnumOptions = (
  values: ReadonlyArray<unknown>,
  names: unknown
): Array<LabeledValue> | undefined => {
  const labels = Array.isArray(names) ? names : []
  const options = values.flatMap((value, index) =>
    typeof value === "string"
      ? [{ label: typeof labels[index] === "string" ? (labels[index] as string) : value, value }]
      : []
  )
  return options.length > 0 ? options : undefined
}

const optionSpec = (option: LabeledValue): { label: string; description?: string } => ({
  label: option.label,
  ...(option.description === undefined ? {} : { description: option.description })
})

/// Lenient mapping from codex question objects to the wire QuestionSpec.
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

const emitQuestionResolved = (
  session: CodexSession,
  questionId: string,
  outcome: "answered" | "cancelled" | "autoResolved",
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

/// Resolves the human's answer back into the held request via the pending
/// entry's source-specific builder. Cancel either sends the source's
/// dismissal reply (MCP elicitations expect `{action: "cancel"}`) or rejects
/// the JSON-RPC request (requestUserInput — codex tells the model the ask
/// was cancelled).
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

/// Turn interrupts, turn completion, and process close all invalidate any
/// still-pending questions: dismiss them at the source and emit the
/// resolution so clients drop the picker instead of hanging on it.
export const cancelPendingQuestions = (session: CodexSession): void => {
  for (const [questionId, pending] of [...session.pendingQuestions]) {
    session.pendingQuestions.delete(questionId)
    if (pending.timer !== undefined) clearTimeout(pending.timer)
    dismissPendingQuestion(pending, "Question cancelled with the turn")
    void emitQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
  }
}
