import type { PromptQueueItem } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { listPromptQueueSync, promptQueueFromRow } from "./row-mappers.js"
import { promptQueueRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { SteeredPromptQueueService } from "./steered-prompt-queue-types.js"

export const makeSteeredPromptQueueService = (
  context: ServiceContext
): SteeredPromptQueueService => {
  const { sqlite, getSession } = context

  return {
    listVisiblePromptQueue: (rawSessionId) =>
      attempt("listVisiblePromptQueue", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return visibleQueue(sqlite, sessionId)
      }),
    markPromptQueueItemSteered: (rawSessionId, queueItemId) =>
      attempt("markPromptQueueItemSteered", () => {
        sqlite.prepare(steeredSql.mark).run(canonicalUuid(rawSessionId), queueItemId)
      }),
    takeSteeredPromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("takeSteeredPromptQueueItem", () =>
        takeSteered(sqlite, canonicalUuid(rawSessionId), queueItemId)
      ),
    releaseSteeredPromptQueueItems: (rawSessionId, queueItemId) =>
      attempt("releaseSteeredPromptQueueItems", () => {
        releaseSteered(sqlite, canonicalUuid(rawSessionId), queueItemId)
      })
  }
}

const visibleQueue = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string
): ReadonlyArray<PromptQueueItem> => [
  ...sqlite
    .prepare(steeredSql.list)
    .all(sessionId)
    .map((row) => promptQueueFromRow(promptQueueRows.one(row))),
  ...listPromptQueueSync(sqlite, sessionId)
]

const takeSteered = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  queueItemId: string
): PromptQueueItem | undefined =>
  sqlite.transaction(() => {
    const row = promptQueueRows.maybe(sqlite.prepare(steeredSql.byId).get(sessionId, queueItemId))
    if (row === undefined) return undefined

    sqlite.prepare(steeredSql.take).run(row.id)
    return promptQueueFromRow({ ...row, steered: 0 })
  })()

const releaseSteered = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  queueItemId: string | undefined
): void => {
  if (queueItemId === undefined) {
    sqlite.prepare(steeredSql.releaseAll).run(sessionId)
    return
  }
  sqlite.prepare(steeredSql.release).run(sessionId, queueItemId)
}

const steeredSql = {
  list: `select * from prompt_queue_items
  where session_id = ? and state = 'processing' and steered = 1
  order by position asc, created_at asc, rowid asc`,
  mark: `update prompt_queue_items set steered = 1
  where session_id = ? and id = ? and state = 'processing'`,
  byId: `select * from prompt_queue_items
  where session_id = ? and id = ? and state = 'processing' and steered = 1`,
  take: "update prompt_queue_items set steered = 0 where id = ?",
  release: `update prompt_queue_items set state = 'pending', steered = 0
  where session_id = ? and id = ? and steered = 1`,
  releaseAll: `update prompt_queue_items set state = 'pending', steered = 0
  where session_id = ? and steered = 1`
}
