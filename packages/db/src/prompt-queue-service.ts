import { randomUUID } from "node:crypto"

import type { PromptQueueItem } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { listPromptQueueSync, promptQueueFromRow, serializeAttachments } from "./row-mappers.js"
import { promptQueueRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

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
  | "releasePromptQueueItem"
  | "listProcessingPromptQueue"
> => {
  const { sqlite, getSession } = context

  return {
    createPromptQueueItem: (rawSessionId, text, attachments, id, clientId, origin) =>
      attempt("createPromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        const now = isoTimestamp()
        const item: PromptQueueItem = {
          id: id ?? randomUUID(),
          sessionId,
          text,
          createdAt: now,
          updatedAt: now,
          ...(attachments === undefined || attachments.length === 0 ? {} : { attachments }),
          ...(clientId === undefined ? {} : { clientId }),
          ...(origin === "system" ? { origin } : {})
        }
        sqlite
          .prepare(queueSql.insert)
          .run(
            item.id,
            sessionId,
            text,
            now,
            now,
            serializeAttachments(attachments),
            clientId ?? null,
            origin ?? "user",
            sessionId
          )
        return item
      }),
    listPromptQueue: (rawSessionId) =>
      attempt("listPromptQueue", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId)
      }),
    updatePromptQueueItem: (rawSessionId, queueItemId, text, attachments) =>
      attempt("updatePromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const now = isoTimestamp()
        const result = sqlite
          .prepare(queueSql.update)
          .run(
            text,
            attachments === undefined ? 0 : 1,
            serializeAttachments(attachments),
            now,
            sessionId,
            queueItemId
          )
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
        return promptQueueFromRow(queueRow(sqlite, sessionId, queueItemId))
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

          const updatePosition = sqlite.prepare(queueSql.setPosition)
          orderedIDs.forEach((id, position) => {
            updatePosition.run(position, sessionId, id)
          })
          return listPromptQueueSync(sqlite, sessionId)
        })
        return transaction()
      }),
    deletePromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("deletePromptQueueItem", () => {
        const result = sqlite.prepare(queueSql.delete).run(canonicalUuid(rawSessionId), queueItemId)
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
      }),
    claimPromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("claimPromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const transaction = sqlite.transaction(() => {
          const row = pendingQueueRow(sqlite, sessionId, queueItemId)
          if (row === undefined) {
            return undefined
          }
          sqlite.prepare(queueSql.claim).run(row.id)
          return promptQueueFromRow(row)
        })
        return transaction()
      }),
    completePromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("completePromptQueueItem", () => {
        sqlite.prepare(queueSql.complete).run(canonicalUuid(rawSessionId), queueItemId)
      }),
    releasePromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("releasePromptQueueItem", () => {
        sqlite.prepare(queueSql.release).run(canonicalUuid(rawSessionId), queueItemId)
      }),
    listProcessingPromptQueue: (rawSessionId) =>
      attempt("listProcessingPromptQueue", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId, "processing")
      })
  }
}

const pendingQueueRow = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  queueItemId: string | undefined
) => {
  if (queueItemId === undefined) {
    return promptQueueRows.maybe(sqlite.prepare(queueSql.nextPending).get(sessionId))
  }
  return promptQueueRows.maybe(sqlite.prepare(queueSql.pending).get(sessionId, queueItemId))
}

const queueRow = (sqlite: ServiceContext["sqlite"], sessionId: string, queueItemId: string) =>
  promptQueueRows.one(sqlite.prepare(queueSql.byId).get(sessionId, queueItemId))

const queueSql = {
  insert: `insert into prompt_queue_items (
              id, session_id, text, created_at, updated_at, attachments, client_id, origin, position
            ) values (?, ?, ?, ?, ?, ?, ?, ?, (
              select coalesce(max(position), -1) + 1
              from prompt_queue_items
              where session_id = ? and state = 'pending'
            ))`,
  update: `update prompt_queue_items
  set text = ?, attachments = iif(?, ?, attachments), updated_at = ?
  where session_id = ? and id = ?`,
  byId: "select * from prompt_queue_items where session_id = ? and id = ?",
  nextPending: `select * from prompt_queue_items
  where session_id = ? and state = 'pending'
  order by position asc, created_at asc, rowid asc
  limit 1`,
  pending: "select * from prompt_queue_items where session_id = ? and state = 'pending' and id = ?",
  setPosition:
    "update prompt_queue_items set position = ? where session_id = ? and state = 'pending' and id = ?",
  delete: "delete from prompt_queue_items where session_id = ? and id = ?",
  claim: "update prompt_queue_items set state = 'processing' where id = ?",
  complete:
    "delete from prompt_queue_items where session_id = ? and id = ? and state = 'processing'",
  release:
    "update prompt_queue_items set state = 'pending' where session_id = ? and id = ? and state = 'processing'"
}
