import { isCompactPrompt, type PromptInput } from "@codevisor/agent-runtime"
import type { PromptQueueItem } from "@codevisor/api"

import {
  resolvePromptAttachments,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { pendingAgentQuestion } from "./parked-questions.js"
import { ensureAgentSessionFor } from "./session-workspace.js"
import { recordUserPrompt, steeredPrompt } from "./user-prompts.js"

interface QuestionReplyTarget {
  readonly agentSessionId: string
  readonly questionId: string
}

export const answeredPendingQuestion = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  item: PromptQueueItem
): Promise<boolean> => {
  if (isCompactPrompt(item.text)) return false
  const question = await pendingAgentQuestion(services, sessionId)
  if (question === undefined) return false

  await recordUserPrompt(services, fanout, serverId, sessionId, steeredPrompt(item))
  const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
  const target = { agentSessionId: agentSession.sessionId, questionId: question.questionId }
  return replyToQuestion(services, target, item)
}

const replyToQuestion = async (
  services: CodevisorServerServices,
  target: QuestionReplyTarget,
  item: Pick<PromptQueueItem, "text" | "attachments">
): Promise<boolean> =>
  run(
    services.agents.replyToQuestion(
      target.agentSessionId,
      target.questionId,
      await replyInput(services, item)
    )
  )

const replyInput = async (
  services: CodevisorServerServices,
  item: Pick<PromptQueueItem, "text" | "attachments">
): Promise<PromptInput> => {
  const refs = item.attachments ?? []
  if (refs.length === 0) return { text: item.text }
  return { attachments: await resolvePromptAttachments(services, refs), text: item.text }
}
