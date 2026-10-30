import type { BackgroundTask, PromptQueueItem } from "@codevisor/api"

import { run, type CodevisorServerServices } from "./server-context.js"

export const restartNotice = (stoppedTasks: ReadonlyArray<string>): string =>
  [
    noticeOpening,
    "Codevisor restarted, which stopped your background tasks:",
    ...stoppedTasks.map((task) => `- ${task}`),
    "They won't report back. Re-run any you still need, then continue.",
    "</codevisor-event>"
  ].join("\n")

export const updateResumeNotice = (stoppedTasks: ReadonlyArray<string>): string =>
  [
    noticeOpening,
    "You were paused while Codevisor updated. Nothing you were doing was rejected — continue your work from where you left off. Any background processes you had running have probably stopped; restart any you still need.",
    ...stoppedTaskLines(stoppedTasks),
    "</codevisor-event>"
  ].join("\n")

const stoppedTaskLines = (stoppedTasks: ReadonlyArray<string>): ReadonlyArray<string> =>
  stoppedTasks.length === 0
    ? []
    : ["These background tasks stopped:", ...stoppedTasks.map((task) => `- ${task}`)]

export const isRestartNotice = (item: PromptQueueItem): boolean =>
  item.origin === "system" && item.text.startsWith(noticeOpening)

export const taskDescriptions = (tasks: ReadonlyArray<BackgroundTask>): ReadonlyArray<string> =>
  tasks.map((task) => task.description.replace(/\s+/g, " ").trim())

export const sessionTaskDescriptions = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<ReadonlyArray<string>> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, 1))
  return taskDescriptions(page.backgroundTasks!)
}

export const queueRestartResumeOnce = async (
  services: CodevisorServerServices,
  sessionId: string,
  text: string
): Promise<void> => {
  const queued = await run(services.db.listPromptQueue(sessionId))
  if (queued.some(isRestartNotice)) return

  await queueSystemPromptFirst(services, sessionId, text)
}

export const queueSystemPromptFirst = async (
  services: CodevisorServerServices,
  sessionId: string,
  text: string
): Promise<void> => {
  const item = await run(
    services.db.createPromptQueueItem(sessionId, text, [], undefined, undefined, "system")
  )
  await run(services.db.reorderPromptQueue(sessionId, [item.id]))
}

const noticeOpening = `<codevisor-event type="session.restarted">`
