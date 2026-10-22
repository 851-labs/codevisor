import type { CodexSession } from "./session.js"

export interface NotificationRoute {
  readonly parentToolCallId: string | undefined
  readonly parentField: { parentToolCallId?: string }
}

export const notificationRoute = (
  session: CodexSession,
  method: string,
  payload: Record<string, unknown>
): NotificationRoute | undefined => {
  const threadId = typeof payload.threadId === "string" ? payload.threadId : undefined
  const isForeign = threadId !== undefined && threadId !== session.threadId
  const parentToolCallId = isForeign ? session.collabThreads.get(threadId) : undefined
  if (isForeign && unroutable(method, parentToolCallId)) return undefined

  return routeTo(parentToolCallId)
}

const subAgentMethods: ReadonlySet<string> = new Set([
  "item/started",
  "item/completed",
  "item/agentMessage/delta",
  "item/reasoning/textDelta",
  "item/reasoning/summaryTextDelta",
  "item/fileChange/patchUpdated",
  "item/commandExecution/outputDelta"
])

const unroutable = (method: string, parentToolCallId: string | undefined): boolean =>
  !subAgentMethods.has(method) || parentToolCallId === undefined

const routeTo = (parentToolCallId: string | undefined): NotificationRoute => ({
  parentToolCallId,
  parentField: parentToolCallId === undefined ? {} : { parentToolCallId }
})
