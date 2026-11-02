import type { PromptQueueItem } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { appendAndPublish, run, type EventFanout } from "../server-context.js"

export const publishPromptQueue = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  sessionId: string
): Promise<ReadonlyArray<PromptQueueItem>> => {
  const queue = await run(db.listVisiblePromptQueue(sessionId))
  await appendAndPublish(db, fanout, "session.queue.updated", sessionId, { queue })
  return queue
}
