import type { QuestionAnswer } from "@codevisor/agent-runtime"
import { isRecord } from "@codevisor/api"
import type { QuestionSpec } from "@codevisor/api"

export interface PendingAcpQuestion {
  readonly sessionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly answer: (answer: QuestionAnswer) => void
  readonly cancel: () => void
  readonly reply: (replyText: string | undefined) => boolean
}

export interface AcpQuestionReply<Response> {
  readonly response: Response
  readonly delivered: boolean
}

export interface AcpMappedQuestion<Response> {
  readonly sessionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly planDocument?: string
  readonly cancelledResponse: Response
  readonly responseFor: (answer: QuestionAnswer) => Response
  readonly replyFor: (replyText: string | undefined) => AcpQuestionReply<Response>
}

export type AcpPermissionOutcome =
  | { outcome: { outcome: "cancelled" } }
  | { outcome: { optionId: string; outcome: "selected" } }

/* v8 ignore start */
export const acpPermissionQuestion = (
  params: unknown
):
  | {
      readonly sessionId: string
      readonly spec: QuestionSpec
      readonly optionIds: ReadonlyMap<string, string>
      readonly rejectOptionId: string | undefined
      readonly planDocument: string | undefined
    }
  | undefined => {
  if (!isRecord(params)) return undefined
  const sessionId = typeof params.sessionId === "string" ? params.sessionId : undefined
  const rawOptions = Array.isArray(params.options) ? params.options : []
  const options = rawOptions.flatMap((option) => {
    if (!isRecord(option)) return []
    return typeof option.optionId === "string" && typeof option.name === "string"
      ? [{ kind: option.kind, name: option.name, optionId: option.optionId }]
      : []
  })
  if (sessionId === undefined || options.length === 0) return undefined
  const toolCall = isRecord(params.toolCall) ? params.toolCall : {}
  const title = typeof toolCall.title === "string" ? toolCall.title : undefined
  const planDocument =
    toolCall.kind === "switch_mode" ? textFromToolCallContent(toolCall.content) : undefined
  return {
    optionIds: new Map(options.map((option) => [option.name, option.optionId])),
    planDocument,
    rejectOptionId: acpRejectOptionId(options),
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
      if (!isRecord(block) || block.type !== "content" || !isRecord(block.content)) return []
      return block.content.type === "text" && typeof block.content.text === "string"
        ? [block.content.text]
        : []
    })
    .join("\n")
    .trim()
  return text.length > 0 ? text : undefined
}

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

export interface AcpPermissionOption {
  readonly kind: unknown
  readonly optionId: string
}

export const acpRejectOptionId = (
  options: ReadonlyArray<AcpPermissionOption>
): string | undefined =>
  optionIdOfKind(options, "reject_once") ?? optionIdOfKind(options, "reject_always")

export const acpPermissionDecline = (
  rejectOptionId: string | undefined
): AcpQuestionReply<AcpPermissionOutcome> => {
  if (rejectOptionId === undefined) {
    return { delivered: false, response: { outcome: { outcome: "cancelled" } } }
  }
  return {
    delivered: false,
    response: { outcome: { optionId: rejectOptionId, outcome: "selected" } }
  }
}

const optionIdOfKind = (
  options: ReadonlyArray<AcpPermissionOption>,
  kind: string
): string | undefined => options.find((option) => option.kind === kind)?.optionId
