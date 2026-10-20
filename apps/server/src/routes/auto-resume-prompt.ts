import type { SessionSummary } from "@codevisor/api"

import { attribute } from "./session-event-messages.js"

export const autoResumePrompt = (
  session: Pick<SessionSummary, "id" | "title">,
  interruptedRequest: string | undefined
): string =>
  [
    `<codevisor-event type="session.usage_limit_reset" sessionId="${attribute(session.id)}" title="${attribute(session.title)}">`,
    continueInstruction,
    ...requestReminder(interruptedRequest),
    "</codevisor-event>"
  ].join("\n")

const continueInstruction =
  "The usage limit that stopped your last turn has reset. Continue the interrupted work from where you left off. Don't start over or repeat steps you already finished."

const requestReminderLimit = 2_000

const requestReminder = (request: string | undefined): ReadonlyArray<string> => {
  const text = request?.trim() ?? ""
  if (text === "") return []

  return ["", "The user's last message, for reference:", bounded(text)]
}

const bounded = (text: string): string => {
  if (text.length <= requestReminderLimit) return text
  return `${text.slice(0, requestReminderLimit)}\n…(truncated)`
}
