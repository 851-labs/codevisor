import type { QuestionSpec } from "@codevisor/api"
import type { QuestionAnswer } from "@codevisor/agent-runtime"

/// One `session/request_permission` held open while the human answers.
export interface PendingAcpQuestion {
  readonly sessionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly cancelledResponse: unknown
  readonly responseFor: (answer: QuestionAnswer) => unknown
  readonly resolve: (response: unknown) => void
}

export type AcpPermissionOutcome =
  | { outcome: { outcome: "cancelled" } }
  | { outcome: { optionId: string; outcome: "selected" } }

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
/// Pure mapping from a permission request onto the question wire shape.
/// Exported for unit tests — the live wiring runs inside the stdio connector.
/// Returns undefined when the request carries no options (auto-cancel).
export const acpPermissionQuestion = (
  params: unknown
):
  | {
      readonly sessionId: string
      readonly spec: QuestionSpec
      readonly optionIds: ReadonlyMap<string, string>
      readonly planDocument: string | undefined
    }
  | undefined => {
  if (typeof params !== "object" || params === null) return undefined
  const request = params as Record<string, unknown>
  const sessionId = typeof request.sessionId === "string" ? request.sessionId : undefined
  const rawOptions = Array.isArray(request.options) ? request.options : []
  const options = rawOptions.flatMap((option) => {
    if (typeof option !== "object" || option === null) return []
    const entry = option as Record<string, unknown>
    return typeof entry.optionId === "string" && typeof entry.name === "string"
      ? [{ name: entry.name, optionId: entry.optionId }]
      : []
  })
  if (sessionId === undefined || options.length === 0) return undefined
  const toolCall =
    typeof request.toolCall === "object" && request.toolCall !== null
      ? (request.toolCall as Record<string, unknown>)
      : {}
  const title = typeof toolCall.title === "string" ? toolCall.title : undefined
  // Plan-mode exits (claude-agent-acp's "Ready to code?") carry the proposed
  // plan markdown as switch_mode tool-call content — surface it as the
  // Proposed Plan card alongside the question.
  const planDocument =
    toolCall.kind === "switch_mode" ? textFromToolCallContent(toolCall.content) : undefined
  return {
    optionIds: new Map(options.map((option) => [option.name, option.optionId])),
    planDocument,
    sessionId,
    spec: {
      allowsOther: false,
      id: "permission",
      options: options.map((option) => ({ label: option.name })),
      question: title !== undefined && title.length > 0 ? title : "Allow the agent to proceed?"
    }
  }
}

const textFromToolCallContent = (content: unknown): string | undefined => {
  if (!Array.isArray(content)) return undefined
  const text = content
    .flatMap((block) => {
      if (typeof block !== "object" || block === null) return []
      const entry = block as { type?: unknown; content?: { type?: unknown; text?: unknown } }
      return entry.type === "content" &&
        entry.content?.type === "text" &&
        typeof entry.content.text === "string"
        ? [entry.content.text]
        : []
    })
    .join("\n")
    .trim()
  return text.length > 0 ? text : undefined
}

/// Maps the human's answer back onto the ACP permission outcome: the selected
/// option label resolves to its optionId; anything else cancels.
export const acpPermissionOutcome = (
  optionIds: ReadonlyMap<string, string>,
  answer: QuestionAnswer
): AcpPermissionOutcome => {
  if (answer.outcome === "answered") {
    const label = Object.values(answer.answers ?? {}).flatMap((entry) => [...entry.answers])[0]
    const optionId = label === undefined ? undefined : optionIds.get(label)
    if (optionId !== undefined) {
      return { outcome: { optionId, outcome: "selected" } }
    }
  }
  return { outcome: { outcome: "cancelled" } }
}
/* v8 ignore stop */
