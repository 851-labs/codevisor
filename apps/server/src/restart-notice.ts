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
