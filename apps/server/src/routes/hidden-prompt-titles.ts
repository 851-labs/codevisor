import type { CodevisorDatabaseService } from "@codevisor/db"

import { run } from "../server-context.js"

const recentItems = 8

export const echoesHiddenPrompt = async (
  db: CodevisorDatabaseService,
  sessionId: string,
  title: string
): Promise<boolean> => {
  const { items } = await run(db.getTranscriptPage(sessionId, undefined, recentItems))
  const prompt = items.findLast((item) => item.role === "user")
  if (prompt?.origin !== "event") return false

  return sameText(prompt.text, title)
}

const sameText = (prompt: string, title: string): boolean =>
  normalized(prompt).startsWith(normalized(title).replace(/(…|\.\.\.)$/, ""))

const normalized = (text: string): string => text.replace(/\s+/g, " ").trim()
