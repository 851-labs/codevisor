import type { TurnTokens } from "@codevisor/agent-runtime"
import type { SessionUsage } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { run } from "../server-context.js"

const tokenFields = [
  "inputTokens",
  "cachedInputTokens",
  "outputTokens",
  "reasoningOutputTokens",
  "totalTokens"
] as const

export const usageAfterTurn = async (
  db: CodevisorDatabaseService,
  sessionId: string,
  tokens: TurnTokens
): Promise<Readonly<Record<string, unknown>>> => {
  const session = await run(db.getSessionSummary(sessionId))
  return { sessionUpdate: "usage_update", ...addedTokens(session.usage, tokens) }
}

const addedTokens = (
  usage: SessionUsage | undefined,
  tokens: TurnTokens
): Readonly<Record<string, number>> =>
  Object.fromEntries(
    tokenFields.flatMap((field) => {
      const turn = tokens[field]
      if (turn === undefined) return []
      return [[field, (usage?.[field] ?? 0) + turn]]
    })
  )
