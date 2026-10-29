import { AgentRuntimeError } from "@codevisor/agent-runtime"
import type { TranscriptItem } from "@codevisor/api"

import { run, type CodevisorServerServices } from "../server-context.js"

export const CONVERSATION_RECAP_MAX_CHARS = 24_000

const RECAP_PAGE_SIZE = 50

const RECAP_INTRO =
  "The agent couldn't resume this chat's earlier session, so this is a new session. " +
  "Here is the conversation so far, for context:"

const pendingRecaps = new WeakMap<CodevisorServerServices, Map<string, string>>()

const recapsFor = (services: CodevisorServerServices): Map<string, string> => {
  const existing = pendingRecaps.get(services)
  if (existing !== undefined) return existing
  const created = new Map<string, string>()
  pendingRecaps.set(services, created)
  return created
}

export const isConversationMissing = (cause: unknown): boolean =>
  cause instanceof AgentRuntimeError && cause.conversationMissing === true

export const rememberConversationRecap = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<void> => {
  const lines = recentLines(earlierItems(await recentItems(services, sessionId)).map(recapLine))
  if (lines.length === 0) return
  recapsFor(services).set(
    sessionId,
    [
      "<codevisor-earlier-conversation>",
      RECAP_INTRO,
      "",
      ...lines,
      "</codevisor-earlier-conversation>"
    ].join("\n")
  )
}

export const withConversationRecap = (
  services: CodevisorServerServices,
  sessionId: string,
  text: string
): string => {
  const recaps = recapsFor(services)
  const recap = recaps.get(sessionId)
  if (recap === undefined) return text
  recaps.delete(sessionId)
  return `${recap}\n\n${text}`
}

const recentItems = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<ReadonlyArray<TranscriptItem>> => {
  const items: Array<TranscriptItem> = []
  let size = 0
  let before: number | undefined
  do {
    const page = await run(services.db.getTranscriptPage(sessionId, before, RECAP_PAGE_SIZE))
    items.unshift(...page.items)
    size += page.items.reduce((total, item) => total + item.text.length, 0)
    before = page.nextBefore === undefined ? undefined : Number(page.nextBefore)
  } while (before !== undefined && size < CONVERSATION_RECAP_MAX_CHARS)
  return items
}

const earlierItems = (
  conversation: ReadonlyArray<TranscriptItem>
): ReadonlyArray<TranscriptItem> => {
  const spoken = conversation.filter((item) => item.text.trim() !== "")
  return spoken.at(-1)?.role === "user" ? spoken.slice(0, -1) : spoken
}

const recapLine = (item: TranscriptItem): string =>
  `${item.role === "user" ? "User" : "Assistant"}: ${item.text.trim()}\n`

const recentLines = (lines: ReadonlyArray<string>): ReadonlyArray<string> => {
  const kept: Array<string> = []
  let size = 0
  for (const line of lines.toReversed()) {
    if (size + line.length > CONVERSATION_RECAP_MAX_CHARS) break
    kept.unshift(line)
    size += line.length
  }
  return kept
}
