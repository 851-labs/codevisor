import type { PromptQueueItem } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { listPromptQueueSync, promptQueueFromRow, serializeAttachments } from "./row-mappers.js"
import type { PromptQueueRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

export const makePromptQueueService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "createPromptQueueItem"
  | "listPromptQueue"
  | "updatePromptQueueItem"
  | "reorderPromptQueue"
  | "deletePromptQueueItem"
  | "claimPromptQueueItem"
  | "completePromptQueueItem"
  | "listProcessingPromptQueue"
> => {
  const { sqlite, getSession } = context

  return {
    // Queue-item ids are deliberately NOT canonicalized: a client-supplied id
    // doubles as the client's optimistic-message token and must echo back
    // byte-identical for identity reconciliation.
    createPromptQueueItem: (rawSessionId, text, attachments, id) =>
      attempt("createPromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        const now = isoTimestamp()
        const item: PromptQueueItem = {
          // A client-supplied id makes the eventual user-echo messageId the
          // client's own optimistic-message id (identity reconciliation).
          id: id ?? randomUUID(),
          sessionId,
          text,
          createdAt: now,
          updatedAt: now,
          ...(attachments === undefined || attachments.length === 0 ? {} : { attachments })
        }
        sqlite
          .prepare(
            `insert into prompt_queue_items (
              id, session_id, text, created_at, updated_at, attachments, position
            ) values (?, ?, ?, ?, ?, ?, (
              select coalesce(max(position), -1) + 1
              from prompt_queue_items
              where session_id = ? and state = 'pending'
            ))`
          )
          .run(item.id, sessionId, text, now, now, serializeAttachments(attachments), sessionId)
        return item
      }),
    listPromptQueue: (rawSessionId) =>
      attempt("listPromptQueue", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId)
      }),
    updatePromptQueueItem: (rawSessionId, queueItemId, text) =>
      attempt("updatePromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const now = isoTimestamp()
        const result = sqlite
          .prepare(
            "update prompt_queue_items set text = ?, updated_at = ? where session_id = ? and id = ?"
          )
          .run(text, now, sessionId, queueItemId)
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
        return promptQueueFromRow(
          sqlite
            .prepare("select * from prompt_queue_items where session_id = ? and id = ?")
            .get(sessionId, queueItemId) as PromptQueueRow
        )
      }),
    reorderPromptQueue: (rawSessionId, queueItemIds) =>
      attempt("reorderPromptQueue", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        const transaction = sqlite.transaction(() => {
          const current = listPromptQueueSync(sqlite, sessionId)
          const currentIDs = new Set(current.map((item) => item.id))
          const seen = new Set<string>()
          const orderedIDs = queueItemIds.filter((id) => {
            if (!currentIDs.has(id) || seen.has(id)) return false
            seen.add(id)
            return true
          })
          orderedIDs.push(...current.map((item) => item.id).filter((id) => !seen.has(id)))

          const updatePosition = sqlite.prepare(
            "update prompt_queue_items set position = ? where session_id = ? and state = 'pending' and id = ?"
          )
          orderedIDs.forEach((id, position) => {
            updatePosition.run(position, sessionId, id)
          })
          return listPromptQueueSync(sqlite, sessionId)
        })
        return transaction()
      }),
    deletePromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("deletePromptQueueItem", () => {
        const result = sqlite
          .prepare("delete from prompt_queue_items where session_id = ? and id = ?")
          .run(canonicalUuid(rawSessionId), queueItemId)
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
      }),
    claimPromptQueueItem: (rawSessionId) =>
      attempt("claimPromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const transaction = sqlite.transaction(() => {
          const row = sqlite
            .prepare(
              `select * from prompt_queue_items
               where session_id = ? and state = 'pending'
               order by position asc, created_at asc, rowid asc
               limit 1`
            )
            .get(sessionId) as PromptQueueRow | undefined
          if (row === undefined) {
            return undefined
          }
          sqlite
            .prepare("update prompt_queue_items set state = 'processing' where id = ?")
            .run(row.id)
          return promptQueueFromRow(row)
        })
        return transaction()
      }),
    completePromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("completePromptQueueItem", () => {
        sqlite
          .prepare(
            "delete from prompt_queue_items where session_id = ? and id = ? and state = 'processing'"
          )
          .run(canonicalUuid(rawSessionId), queueItemId)
      }),
    listProcessingPromptQueue: (rawSessionId) =>
      attempt("listProcessingPromptQueue", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId, "processing")
      })
  }
}
