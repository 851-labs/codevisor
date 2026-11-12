import type { PromptQueueItem } from "@codevisor/api"

import { run, type CodevisorServerServices } from "../server-context.js"
import { HANDOFF_CLOSING, HANDOFF_OPENING } from "./bot-handoff-text.js"

export const queueHandoff = async (
  services: CodevisorServerServices,
  sessionId: string,
  text: string
): Promise<void> => {
  await run(services.db.createPromptQueueItem(sessionId, text, [], undefined, undefined, "system"))
}

export const heldForHandoff = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> => {
  const queue = await run(services.db.listPromptQueue(sessionId))
  return queue.length > 0 && queue.every(isHandoff)
}

export const attachHandoff = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<void> => {
  const [first, next] = await run(services.db.listPromptQueue(sessionId))
  if (first === undefined || next === undefined || !isHandoff(first)) return

  const text = `${first.text}\n\n${next.text}`
  await run(services.db.updatePromptQueueItem(sessionId, next.id, text, undefined))
  await run(services.db.deletePromptQueueItem(sessionId, first.id))
}

const isHandoff = (item: PromptQueueItem): boolean =>
  item.origin === "system" && isOnlyHandoff(item.text)

const isOnlyHandoff = (text: string): boolean =>
  text.startsWith(HANDOFF_OPENING) &&
  text.indexOf(HANDOFF_CLOSING) === text.length - HANDOFF_CLOSING.length
