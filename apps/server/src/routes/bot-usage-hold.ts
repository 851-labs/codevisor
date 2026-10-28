import type { PromptQueueItem } from "@codevisor/api"

import { run, type CodevisorServerServices } from "../server-context.js"
import { conversationalBotForSession } from "./bot-turns.js"

export const heldForUsageLimit = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> => {
  if (!(await botAwaitsReset(services, sessionId))) return false
  return !(await userPromptQueued(services, sessionId))
}

export const coalesceWakeUps = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<void> => {
  const wakeUps = leadingWakeUps(await run(services.db.listPromptQueue(sessionId)))
  if (wakeUps.length < 2) return

  const [first, ...rest] = wakeUps
  await run(services.db.updatePromptQueueItem(sessionId, first!.id, combined(wakeUps), undefined))
  for (const item of rest) await run(services.db.deletePromptQueueItem(sessionId, item.id))
}

const botAwaitsReset = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> => {
  const resume = await run(services.db.getAutoResume(sessionId))
  if (resume?.state !== "waiting") return false

  return (await conversationalBotForSession(services, sessionId)) !== undefined
}

const userPromptQueued = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> =>
  (await run(services.db.listPromptQueue(sessionId))).some((item) => item.origin !== "system")

const leadingWakeUps = (queue: ReadonlyArray<PromptQueueItem>): ReadonlyArray<PromptQueueItem> => {
  const end = queue.findIndex((item) => !isWakeUp(item))
  if (end === -1) return queue

  return queue.slice(0, end)
}

const isWakeUp = (item: PromptQueueItem): boolean => item.origin === "system"

const combined = (wakeUps: ReadonlyArray<PromptQueueItem>): string =>
  wakeUps.map((item) => item.text).join("\n\n")
