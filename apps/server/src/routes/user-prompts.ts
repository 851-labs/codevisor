import type { AttachmentRef, PromptOrigin, PromptQueueItem } from "@codevisor/api"

import type { CodevisorServerServices, EventFanout } from "../server-context.js"
import { transcriptOrigin } from "./prompt-origin.js"
import { materializeRuntimeEvent } from "./session-events.js"

export interface RecordedPrompt {
  readonly messageId: string
  readonly text: string
  readonly attachments: ReadonlyArray<AttachmentRef> | undefined
  readonly origin: PromptOrigin | undefined
  readonly startsTurn: boolean
}

export const recordUserPrompt = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  prompt: RecordedPrompt
): Promise<void> => {
  const { messageId, text, startsTurn } = prompt
  const refs = prompt.attachments ?? []
  return materializeRuntimeEvent(
    services.db,
    fanout,
    serverId,
    {
      kind: "session.output",
      subjectId: sessionId,
      payload: {
        role: "user",
        messageId,
        ...(startsTurn ? { startsTurn: true } : {}),
        text,
        ...(refs.length === 0 ? {} : { attachments: refs }),
        ...transcriptOrigin(prompt.origin)
      }
    },
    sessionId
  )
}

export const steeredPrompt = (item: PromptQueueItem): RecordedPrompt => ({
  messageId: item.id,
  text: item.text,
  attachments: item.attachments,
  origin: item.origin,
  startsTurn: false
})
