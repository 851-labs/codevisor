import type { QuestionSpec } from "@codevisor/api"
import type { AcpMappedQuestion } from "@codevisor/adapter-acp"
import type { RuntimeEvent } from "@codevisor/agent-runtime"

type CursorTodoStatus = "pending" | "in_progress" | "completed" | "cancelled"

interface CursorQuestionOption {
  readonly id: string
  readonly label: string
}

interface CursorQuestion {
  readonly id: string
  readonly prompt: string
  readonly options: ReadonlyArray<CursorQuestionOption>
  readonly allowMultiple: boolean
}

interface CursorTodo {
  readonly id: string
  readonly content: string
  readonly status: CursorTodoStatus
}

export type CursorAskQuestionResponse = {
  readonly outcome:
    | {
        readonly outcome: "answered"
        readonly answers: ReadonlyArray<{
          readonly questionId: string
          readonly selectedOptionIds: ReadonlyArray<string>
        }>
      }
    | { readonly outcome: "skipped"; readonly reason?: string }
    | { readonly outcome: "cancelled" }
}

export type CursorCreatePlanResponse = {
  readonly outcome:
    | { readonly outcome: "accepted"; readonly planUri?: string }
    | { readonly outcome: "rejected"; readonly reason?: string }
    | { readonly outcome: "cancelled" }
}

const record = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null ? (value as Record<string, unknown>) : undefined

const cursorQuestions = (value: unknown): ReadonlyArray<CursorQuestion> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((rawQuestion) => {
    const question = record(rawQuestion)
    if (
      question === undefined ||
      typeof question.id !== "string" ||
      typeof question.prompt !== "string" ||
      !Array.isArray(question.options)
    ) {
      return []
    }
    const options = question.options.flatMap((rawOption) => {
      const option = record(rawOption)
      return option !== undefined &&
        typeof option.id === "string" &&
        typeof option.label === "string"
        ? [{ id: option.id, label: option.label }]
        : []
    })
    if (options.length === 0) return []
    return [
      {
        id: question.id,
        prompt: question.prompt,
        options,
        allowMultiple: question.allowMultiple === true
      }
    ]
  })
}

export const cursorAskQuestion = (
  params: unknown,
  sessionId: string
): AcpMappedQuestion<CursorAskQuestionResponse> | undefined => {
  const request = record(params)
  if (request === undefined || typeof request.toolCallId !== "string") return undefined
  const sourceQuestions = cursorQuestions(request.questions)
  if (sourceQuestions.length === 0) return undefined
  const questions: ReadonlyArray<QuestionSpec> = sourceQuestions.map((question) => ({
    id: question.id,
    ...(typeof request.title === "string" ? { header: request.title } : {}),
    question: question.prompt,
    options: question.options.map((option) => ({ id: option.id, label: option.label })),
    ...(question.allowMultiple ? { multiSelect: true } : {}),
    allowsOther: false
  }))
  return {
    sessionId,
    questions,
    cancelledResponse: { outcome: { outcome: "cancelled" } },
    responseFor: (answer) => {
      if (answer.outcome === "cancelled") return { outcome: { outcome: "cancelled" } }
      const answers = sourceQuestions.flatMap((question) => {
        const selected = answer.answers?.[question.id]?.answers ?? []
        const optionIds = selected.flatMap((label) => {
          const option = question.options.find((candidate) => candidate.label === label)
          return option === undefined ? [] : [option.id]
        })
        return optionIds.length === 0
          ? []
          : [{ questionId: question.id, selectedOptionIds: optionIds }]
      })
      return answers.length === 0
        ? { outcome: { outcome: "skipped", reason: "No answers selected" } }
        : { outcome: { outcome: "answered", answers } }
    }
  }
}

const CURSOR_PLAN_QUESTION_ID = "cursor_create_plan"
const ACCEPT_PLAN = "Accept plan"
const REJECT_PLAN = "Reject plan"

export const cursorCreatePlanQuestion = (
  params: unknown,
  sessionId: string
): AcpMappedQuestion<CursorCreatePlanResponse> | undefined => {
  const request = record(params)
  if (
    request === undefined ||
    typeof request.toolCallId !== "string" ||
    typeof request.plan !== "string"
  ) {
    return undefined
  }
  return {
    sessionId,
    questions: [
      {
        id: CURSOR_PLAN_QUESTION_ID,
        header: typeof request.name === "string" ? request.name : "Plan",
        question:
          typeof request.overview === "string" && request.overview.length > 0
            ? request.overview
            : "Ready to implement this plan?",
        options: [{ label: ACCEPT_PLAN }, { label: REJECT_PLAN }],
        allowsOther: true
      }
    ],
    ...(request.plan.length === 0 ? {} : { planDocument: request.plan }),
    cancelledResponse: { outcome: { outcome: "cancelled" } },
    responseFor: (answer) => {
      if (answer.outcome === "cancelled") return { outcome: { outcome: "cancelled" } }
      const entry = answer.answers?.[CURSOR_PLAN_QUESTION_ID]
      const selected = entry?.answers[0]
      if (selected === ACCEPT_PLAN) return { outcome: { outcome: "accepted" } }
      const note = entry?.note?.trim()
      const custom =
        selected === undefined || selected === REJECT_PLAN ? undefined : selected.trim()
      const reason = note === undefined || note.length === 0 ? custom : note
      return {
        outcome: {
          outcome: "rejected",
          ...(reason === undefined || reason.length === 0 ? {} : { reason })
        }
      }
    }
  }
}

const parseTodos = (value: unknown): ReadonlyArray<CursorTodo> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((rawTodo) => {
    const todo = record(rawTodo)
    if (
      todo === undefined ||
      typeof todo.id !== "string" ||
      typeof todo.content !== "string" ||
      todo.content.length === 0
    ) {
      return []
    }
    const status: CursorTodoStatus =
      todo.status === "in_progress" || todo.status === "completed" || todo.status === "cancelled"
        ? todo.status
        : "pending"
    return [{ id: todo.id, content: todo.content, status }]
  })
}

export class CursorTodoTracker {
  private readonly sessions = new Map<string, ReadonlyArray<CursorTodo>>()

  update(sessionId: string, params: unknown): RuntimeEvent | undefined {
    const request = record(params)
    if (request === undefined || typeof request.toolCallId !== "string") return undefined
    const incoming = parseTodos(request.todos)
    if (!Array.isArray(request.todos)) return undefined
    const todos = request.merge === true ? this.merge(sessionId, incoming) : incoming
    this.sessions.set(sessionId, todos)
    return {
      kind: "session.output",
      subjectId: sessionId,
      payload: {
        entries: todos.map((todo) => ({
          content: todo.content,
          priority: "medium",
          status: todo.status === "cancelled" ? "completed" : todo.status
        })),
        sessionUpdate: "plan"
      }
    }
  }

  private merge(sessionId: string, incoming: ReadonlyArray<CursorTodo>): ReadonlyArray<CursorTodo> {
    const merged = [...(this.sessions.get(sessionId) ?? [])]
    const indexes = new Map(merged.map((todo, index) => [todo.id, index]))
    for (const todo of incoming) {
      const index = indexes.get(todo.id)
      if (index === undefined) {
        indexes.set(todo.id, merged.length)
        merged.push(todo)
      } else {
        merged[index] = todo
      }
    }
    return merged
  }
}

export const cursorTaskEvent = (params: unknown, sessionId: string): RuntimeEvent | undefined => {
  const request = record(params)
  if (request === undefined || typeof request.toolCallId !== "string") return undefined
  const description =
    typeof request.description === "string" && request.description.length > 0
      ? request.description
      : "Subagent task"
  return {
    kind: "session.output",
    subjectId: sessionId,
    payload: {
      kind: "agent",
      rawInput: {
        ...(typeof request.prompt === "string" ? { prompt: request.prompt } : {}),
        ...(request.subagentType === undefined ? {} : { subagentType: request.subagentType }),
        ...(typeof request.model === "string" ? { model: request.model } : {})
      },
      rawOutput: {
        ...(typeof request.agentId === "string" ? { agentId: request.agentId } : {}),
        ...(typeof request.durationMs === "number" ? { durationMs: request.durationMs } : {})
      },
      sessionUpdate: "tool_call",
      status: "completed",
      title: description,
      toolCallId: request.toolCallId
    }
  }
}

export const cursorGenerateImageEvent = (
  params: unknown,
  sessionId: string
): RuntimeEvent | undefined => {
  const request = record(params)
  if (request === undefined || typeof request.toolCallId !== "string") return undefined
  const filePath = typeof request.filePath === "string" ? request.filePath : undefined
  return {
    kind: "session.output",
    subjectId: sessionId,
    payload: {
      kind: "other",
      ...(filePath === undefined ? {} : { locations: [{ path: filePath }] }),
      rawInput: {
        ...(typeof request.description === "string" ? { description: request.description } : {}),
        ...(Array.isArray(request.referenceImagePaths)
          ? { referenceImagePaths: request.referenceImagePaths }
          : {})
      },
      ...(filePath === undefined ? {} : { rawOutput: { filePath } }),
      sessionUpdate: "tool_call_update",
      status: "completed",
      toolCallId: request.toolCallId
    }
  }
}
