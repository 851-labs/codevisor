import type { GoalStatus, QuestionSpec, SessionGoal, SessionModeState } from "@codevisor/api"
import type { QuestionAnswer, RuntimeEvent } from "@codevisor/agent-runtime"

export interface GrokMappedQuestion<Response> {
  readonly sessionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly planDocument?: string
  readonly cancelledResponse: Response
  readonly responseFor: (answer: QuestionAnswer) => Response
}

export type GrokPlanApprovalResponse =
  | { readonly outcome: "approved" | "abandoned" }
  | { readonly outcome: "cancelled"; readonly feedback?: string }

export type GrokAskUserQuestionResponse =
  | { readonly outcome: "cancelled" }
  | {
      readonly outcome: "accepted"
      readonly answers: Readonly<Record<string, ReadonlyArray<string>>>
      readonly annotations?: Readonly<
        Record<string, { readonly preview?: string; readonly notes?: string }>
      >
    }

export interface GrokGoalNotification {
  readonly sessionId: string
  readonly goal: SessionGoal | undefined
  readonly event: RuntimeEvent
}

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
const GROK_PLAN_QUESTION_ID = "grok_exit_plan_mode"
const GROK_IMPLEMENT_PLAN_LABEL = "Implement plan"
const GROK_KEEP_PLANNING_LABEL = "Keep planning"
const GROK_ABANDON_PLAN_LABEL = "Abandon plan"

const unwrapGrokExtensionParams = (params: unknown): unknown => {
  if (typeof params !== "object" || params === null) return params
  const wrapper = params as Record<string, unknown>
  return typeof wrapper.method === "string" && wrapper.params !== undefined
    ? wrapper.params
    : params
}

const grokGoalStatus = (status: string): GoalStatus | undefined => {
  switch (status) {
    case "active":
      return "active"
    case "user_paused":
    case "back_off_paused":
    case "no_progress_paused":
    case "doom_loop_paused":
      return "paused"
    case "infra_paused":
    case "blocked":
      return "blocked"
    case "budget_limited":
      return "budgetLimited"
    case "complete":
      return "complete"
    default:
      return undefined
  }
}

/// Maps Grok's x.ai goal progress extension onto Codevisor's shared goal
/// snapshot. The lookup preserves createdAt across the many progress ticks.
export const grokGoalNotification = (
  params: unknown,
  currentGoal: (sessionId: string) => SessionGoal | undefined = () => undefined,
  now = new Date().toISOString()
): GrokGoalNotification | undefined => {
  params = unwrapGrokExtensionParams(params)
  if (typeof params !== "object" || params === null) return undefined
  const notification = params as Record<string, unknown>
  if (typeof notification.sessionId !== "string") return undefined
  if (typeof notification.update !== "object" || notification.update === null) return undefined
  const update = notification.update as Record<string, unknown>
  if (update.sessionUpdate !== "goal_updated" || typeof update.status !== "string") {
    return undefined
  }
  if (update.status === "cleared") {
    return {
      sessionId: notification.sessionId,
      goal: undefined,
      event: {
        kind: "session.updated",
        subjectId: notification.sessionId,
        payload: { goalCleared: true }
      }
    }
  }
  const status = grokGoalStatus(update.status)
  if (status === undefined || typeof update.objective !== "string") return undefined
  const previous = currentGoal(notification.sessionId)
  const tokenBudget =
    typeof update.token_budget === "number" && Number.isFinite(update.token_budget)
      ? update.token_budget
      : null
  const tokensUsed =
    typeof update.tokens_used === "number" && Number.isFinite(update.tokens_used)
      ? update.tokens_used
      : 0
  const timeUsedSeconds =
    typeof update.elapsed_ms === "number" && Number.isFinite(update.elapsed_ms)
      ? update.elapsed_ms / 1_000
      : 0
  const goal: SessionGoal = {
    objective: update.objective,
    status,
    ...(update.verifying_completion === true
      ? { activity: "verifying" as const }
      : update.planning === true
        ? { activity: "planning" as const }
        : {}),
    tokenBudget,
    tokensUsed,
    timeUsedSeconds,
    createdAt: previous?.createdAt ?? now,
    updatedAt: now
  }
  return {
    sessionId: notification.sessionId,
    goal,
    event: {
      kind: "session.updated",
      subjectId: notification.sessionId,
      payload: { goal }
    }
  }
}

export const grokPlanApprovalQuestion = (
  params: unknown
): GrokMappedQuestion<GrokPlanApprovalResponse> | undefined => {
  params = unwrapGrokExtensionParams(params)
  if (typeof params !== "object" || params === null) return undefined
  const request = params as Record<string, unknown>
  if (typeof request.sessionId !== "string") return undefined
  const planDocument = typeof request.planContent === "string" ? request.planContent : undefined
  const questions: ReadonlyArray<QuestionSpec> = [
    {
      id: GROK_PLAN_QUESTION_ID,
      header: "Plan",
      question: "Ready to implement this plan?",
      options: [
        { label: GROK_IMPLEMENT_PLAN_LABEL, description: "Start building" },
        { label: GROK_KEEP_PLANNING_LABEL, description: "Keep refining the plan" },
        { label: GROK_ABANDON_PLAN_LABEL, description: "Exit plan mode without implementing" }
      ],
      allowsOther: true
    }
  ]
  return {
    sessionId: request.sessionId,
    questions,
    ...(planDocument === undefined ? {} : { planDocument }),
    cancelledResponse: { outcome: "cancelled" },
    responseFor: (answer) => {
      if (answer.outcome === "cancelled") return { outcome: "cancelled" }
      const entry = answer.answers?.[GROK_PLAN_QUESTION_ID]
      const selected = entry?.answers[0]
      if (selected === GROK_IMPLEMENT_PLAN_LABEL) return { outcome: "approved" }
      if (selected === GROK_ABANDON_PLAN_LABEL) return { outcome: "abandoned" }
      const note = entry?.note?.trim()
      const freeform =
        selected !== undefined &&
        ![GROK_KEEP_PLANNING_LABEL, GROK_IMPLEMENT_PLAN_LABEL, GROK_ABANDON_PLAN_LABEL].includes(
          selected
        )
          ? selected.trim()
          : ""
      const feedback = note === undefined || note === "" ? freeform : note
      return feedback === "" ? { outcome: "cancelled" } : { outcome: "cancelled", feedback }
    }
  }
}

interface GrokQuestionOption {
  readonly label: string
  readonly description?: string
  readonly preview?: string
}

interface GrokQuestion {
  readonly question: string
  readonly options: ReadonlyArray<GrokQuestionOption>
  readonly multiSelect: boolean
}

const parseGrokQuestions = (value: unknown): ReadonlyArray<GrokQuestion> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    if (typeof entry !== "object" || entry === null) return []
    const question = entry as Record<string, unknown>
    if (typeof question.question !== "string" || !Array.isArray(question.options)) return []
    const options = question.options.flatMap((raw) => {
      if (typeof raw !== "object" || raw === null) return []
      const option = raw as Record<string, unknown>
      if (typeof option.label !== "string") return []
      return [
        {
          label: option.label,
          ...(typeof option.description === "string" ? { description: option.description } : {}),
          ...(typeof option.preview === "string" ? { preview: option.preview } : {})
        }
      ]
    })
    return [
      {
        question: question.question,
        options,
        multiSelect: question.multiSelect === true
      }
    ]
  })
}

export const grokAskUserQuestion = (
  params: unknown
): GrokMappedQuestion<GrokAskUserQuestionResponse> | undefined => {
  params = unwrapGrokExtensionParams(params)
  if (typeof params !== "object" || params === null) return undefined
  const request = params as Record<string, unknown>
  if (typeof request.sessionId !== "string") return undefined
  const grokQuestions = parseGrokQuestions(request.questions)
  if (grokQuestions.length === 0) return undefined
  const questions: ReadonlyArray<QuestionSpec> = grokQuestions.map((question) => ({
    id: question.question,
    question: question.question,
    options: question.options.map((option) => ({
      label: option.label,
      ...(option.description === undefined ? {} : { description: option.description })
    })),
    ...(question.multiSelect ? { multiSelect: true } : {}),
    allowsOther: true
  }))
  return {
    sessionId: request.sessionId,
    questions,
    cancelledResponse: { outcome: "cancelled" },
    responseFor: (answer) => {
      if (answer.outcome === "cancelled") return { outcome: "cancelled" }
      const answers: Record<string, ReadonlyArray<string>> = {}
      const annotations: Record<string, { readonly preview?: string; readonly notes?: string }> = {}
      for (const question of grokQuestions) {
        const entry = answer.answers?.[question.question]
        if (entry === undefined) continue
        const knownLabels = new Set(question.options.map((option) => option.label))
        const unknown = entry.answers.find((selected) => !knownLabels.has(selected))
        const selected = entry.answers.filter((label) => knownLabels.has(label))
        const notes = entry.note?.trim() || unknown?.trim()
        if (selected.length === 0 && (notes === undefined || notes === "")) continue
        answers[question.question] =
          selected.length === 0 && notes !== undefined ? ["Other"] : selected
        const preview =
          question.multiSelect || selected.length !== 1
            ? undefined
            : question.options.find((option) => option.label === selected[0])?.preview
        if (preview !== undefined || (notes !== undefined && notes !== "")) {
          annotations[question.question] = {
            ...(preview === undefined ? {} : { preview }),
            ...(notes === undefined || notes === "" ? {} : { notes })
          }
        }
      }
      return {
        outcome: "accepted",
        answers,
        ...(Object.keys(annotations).length === 0 ? {} : { annotations })
      }
    }
  }
}
/* v8 ignore stop */

/// Grok implements `session/set_mode` for these ids but currently omits the
/// standard ACP `modes` field from session/new and session/load responses.
/// Advertising the known modes lets Codevisor's existing plan toggle drive
/// the upstream plan-mode state machine.
export const grokModeState: SessionModeState = {
  currentModeId: "default",
  availableModes: [
    {
      id: "default",
      name: "Build",
      description: "Work normally with the configured permissions.",
      canonicalId: "fullAccess"
    },
    {
      id: "plan",
      name: "Plan",
      description: "Explore and propose a plan before implementation.",
      canonicalId: "plan"
    },
    {
      id: "ask",
      name: "Ask",
      description: "Answer questions without making changes.",
      canonicalId: "ask"
    }
  ]
}
