import type { DataUpgradeProgress } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"

import { chatState, createChatItem, setChatRoute } from "./chat-items.js"
import { backfillJobRows, countRows, idRows, readInstanceMeta } from "./common-rows.js"
import { insertSessionEvent, projectChatEvent } from "./event-projection.js"
import { parseAttachments } from "./row-mappers.js"
import { integer, rowReader } from "./row-reader.js"
import { conversationRows, eventRows, transcriptRows, type TranscriptRow } from "./rows.js"
import type { CodevisorDatabaseConfig } from "./service.js"
import { runTranscriptStateUpgrade } from "./transcript-state-upgrade.js"

const canonicalChatBackfillId = "canonical-session-chat-v1"

const rowIdRows = rowReader({ row_id: integer })

const eventSizeRows = rowReader({ id: integer, bytes: integer })

const legacyConversationRows = rowReader({ ...conversationRows.columns, row_id: integer })

const countOf = (sqlite: Database.Database, sql: string): number =>
  countRows.one(sqlite.prepare(sql).get()).count

const reportDataUpgrade = (
  config: CodevisorDatabaseConfig,
  progress: DataUpgradeProgress
): void => {
  config.onDataUpgradeProgress?.(progress)
}

const copyTranscriptItemToChat = (sqlite: Database.Database, row: TranscriptRow): void => {
  const attachments = parseAttachments(row.attachments)
  const itemId = createChatItem(sqlite, row.session_id, row.role, row.created_at, {
    id: row.id,
    position: row.sequence,
    text: row.text,
    status: row.is_generating === 1 ? "streaming" : "complete",
    ...(row.plan_document === null ? {} : { planDocument: row.plan_document }),
    ...(row.turn_id === null ? {} : { turnId: row.turn_id }),
    ...(row.started_at === null ? {} : { startedAt: row.started_at }),
    ...(row.ended_at === null ? {} : { completedAt: row.ended_at }),
    ...(row.stop_reason === null ? {} : { stopReason: row.stop_reason }),
    ...(row.stop_detail === null ? {} : { stopDetail: row.stop_detail }),
    retryable: row.retryable === 1,
    ...(attachments === undefined ? {} : { attachments }),
    hasDetails: row.has_details === 1,
    revision: row.revision
  })
  if (row.turn_id !== null) setChatRoute(sqlite, row.session_id, `turn:${row.turn_id}`, itemId)
}

const runCanonicalChatBackfill = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): void => {
  const existing = backfillJobRows.maybe(
    sqlite
      .prepare("select state, cursor, completed, total from backfill_jobs where id = ?")
      .get(canonicalChatBackfillId)
  )
  if (existing?.state === "completed") {
    reportDataUpgrade(config, {
      state: "completed",
      id: canonicalChatBackfillId,
      name: "Updating chat history",
      completed: existing.total,
      total: existing.total
    })
    return
  }

  const transcriptTotal = countOf(sqlite, "select count(*) as count from transcript_items")
  const eventTotal = countOf(
    sqlite,
    `select count(*) as count from events
           where exists (select 1 from sessions where sessions.id = events.subject_id)`
  )
  const sessionTotal = countOf(sqlite, "select count(*) as count from sessions")
  const total = Math.max(1, transcriptTotal + eventTotal + sessionTotal)
  let completed = Math.min(existing?.completed ?? 0, total)
  let eventCursor = Number(existing?.cursor ?? 0)
  const progress = (state: DataUpgradeProgress["state"], error?: string): void => {
    const value: DataUpgradeProgress = {
      state,
      id: canonicalChatBackfillId,
      name: "Updating chat history",
      completed: state === "completed" ? total : Math.min(completed, total),
      total,
      ...(error === undefined ? {} : { error })
    }
    reportDataUpgrade(config, value)
  }
  sqlite
    .prepare(
      `insert into backfill_jobs (id, name, state, cursor, completed, total, error, updated_at)
       values (?, ?, 'running', null, ?, ?, null, ?)
       on conflict(id) do update set state = 'running', total = excluded.total,
         error = null, updated_at = excluded.updated_at`
    )
    .run(
      canonicalChatBackfillId,
      "Build canonical session chat store",
      completed,
      total,
      isoTimestamp()
    )
  progress("running")

  const checkpoint = (delta: number): void => {
    completed = Math.min(total, completed + delta)
    sqlite
      .prepare("update backfill_jobs set completed = ?, cursor = ?, updated_at = ? where id = ?")
      .run(completed, String(eventCursor), isoTimestamp(), canonicalChatBackfillId)
    progress("running")
  }

  try {
    let transcriptCursor = 0
    while (true) {
      const rows = rowIdRows.all(
        sqlite
          .prepare(
            `select transcript_items.rowid as row_id from transcript_items
           left join chat_items on chat_items.id = transcript_items.id
           where transcript_items.rowid > ? and chat_items.id is null order by transcript_items.rowid asc limit 100`
          )
          .all(transcriptCursor)
      )
      if (rows.length === 0) break
      sqlite.transaction(() => {
        for (const row of rows) {
          copyTranscriptItemToChat(
            sqlite,
            transcriptRows.one(
              sqlite.prepare("select * from transcript_items where rowid = ?").get(row.row_id)
            )
          )
          transcriptCursor = row.row_id
        }
      })()
      checkpoint(rows.length)
    }

    sqlite.exec(`
      insert into chat_item_routes (session_id, route_key, item_id)
        select transcript_routes.session_id, transcript_routes.route_key, transcript_routes.item_id
        from transcript_routes
        join chat_items on chat_items.id = transcript_routes.item_id
        on conflict(session_id, route_key) do nothing;
    `)

    while (true) {
      const rows = eventSizeRows.all(
        sqlite
          .prepare(
            `select events.id, length(cast(events.payload as blob)) as bytes from events
           join sessions on sessions.id = events.subject_id
           left join session_events on session_events.global_event_id = events.id
           where events.id > ? and session_events.global_event_id is null
           order by events.id asc limit 256`
          )
          .all(eventCursor)
      )
      if (rows.length === 0) break
      sqlite.transaction(() => {
        let bytes = 0
        for (const candidate of rows) {
          if (bytes > 0 && bytes + candidate.bytes > 2 * 1024 * 1024) break
          const row = eventRows.one(
            sqlite.prepare("select * from events where id = ?").get(candidate.id)
          )
          bytes += candidate.bytes
          const linkedItem =
            row.transcript_item_id !== null &&
            sqlite.prepare("select 1 from chat_items where id = ?").get(row.transcript_item_id) !==
              undefined
              ? row.transcript_item_id
              : null
          const event = insertSessionEvent(sqlite, {
            session_id: row.subject_id,
            global_event_id: row.id,
            server_id: row.server_id,
            kind: row.kind,
            created_at: row.created_at,
            payload: row.payload,
            chat_item_id: linkedItem
          })
          const hasTranscript =
            sqlite
              .prepare("select 1 from transcript_items where session_id = ? limit 1")
              .get(row.subject_id) !== undefined
          if (!hasTranscript) projectChatEvent(sqlite, event)
          eventCursor = row.id
          completed = Math.min(total, completed + 1)
        }
        sqlite
          .prepare(
            "update backfill_jobs set completed = ?, cursor = ?, updated_at = ? where id = ?"
          )
          .run(completed, String(eventCursor), isoTimestamp(), canonicalChatBackfillId)
      })()
      progress("running")
    }

    const sessions = idRows.all(sqlite.prepare("select id from sessions order by id").all())
    for (const session of sessions) {
      sqlite.transaction(() => {
        const hasChat =
          sqlite
            .prepare("select 1 from chat_items where session_id = ? limit 1")
            .get(session.id) !== undefined
        if (!hasChat) {
          let timestamp = ""
          let rowid = 0
          while (true) {
            const row = legacyConversationRows.maybe(
              sqlite
                .prepare(
                  `select rowid as row_id, * from conversation_items where session_id = ?
              and (created_at, rowid) > (?, ?) order by created_at, rowid limit 1`
                )
                .get(session.id, timestamp, rowid)
            )
            if (row === undefined) break
            timestamp = row.created_at
            rowid = row.row_id
            const attachments = parseAttachments(row.attachments)
            createChatItem(sqlite, session.id, row.role, row.created_at, {
              text: row.text,
              status: row.is_generating === 1 ? "streaming" : "complete",
              ...(attachments === undefined ? {} : { attachments })
            })
          }
        }
        chatState(sqlite, session.id)
      })()
      checkpoint(1)
    }

    const missingTranscript = countOf(
      sqlite,
      `select count(*) as count from transcript_items
             left join chat_items on chat_items.id = transcript_items.id
             where chat_items.id is null`
    )
    const missingEvents = countOf(
      sqlite,
      `select count(*) as count from events
             join sessions on sessions.id = events.subject_id
             left join session_events on session_events.global_event_id = events.id
             where session_events.global_event_id is null`
    )
    const mismatchedTranscript = countOf(
      sqlite,
      `select count(*) as count from transcript_items legacy
             join chat_items item on item.id = legacy.id
             left join chat_parts text_part
               on text_part.item_id = item.id and text_part.kind = 'text'
             left join chat_parts plan_part
               on plan_part.item_id = item.id and plan_part.kind = 'plan'
             where item.session_id != legacy.session_id
                or item.position != legacy.sequence
                or item.role != legacy.role
                or coalesce(text_part.text, '') != legacy.text
                or coalesce(plan_part.text, '') != coalesce(legacy.plan_document, '')
                or coalesce(item.attachments, '') != coalesce(legacy.attachments, '')`
    )
    if (missingTranscript !== 0 || missingEvents !== 0 || mismatchedTranscript !== 0) {
      throw new Error(
        `Canonical chat verification failed: ${missingTranscript} transcript items missing, ${mismatchedTranscript} differ, and ${missingEvents} session events are missing`
      )
    }

    sqlite
      .prepare(
        `update backfill_jobs set state = 'completed', completed = total, error = null,
         updated_at = ? where id = ?`
      )
      .run(isoTimestamp(), canonicalChatBackfillId)
    completed = total
    progress("completed")
  } catch (cause) {
    /* v8 ignore next */
    const message = cause instanceof Error ? cause.message : String(cause)
    sqlite
      .prepare("update backfill_jobs set state = 'failed', error = ?, updated_at = ? where id = ?")
      .run(message, isoTimestamp(), canonicalChatBackfillId)
    progress("failed", message)
    throw cause
  }
}

const adoptServerIdentity = (sqlite: Database.Database, config: CodevisorDatabaseConfig): void => {
  sqlite.transaction(() => {
    if (readInstanceMeta(sqlite, "adopted-server-id") === config.serverId) return
    for (const table of ["sessions", "events", "session_events"]) {
      sqlite
        .prepare(`update ${table} set server_id = ? where server_id != ?`)
        .run(config.serverId, config.serverId)
    }
    for (const table of ["project_locations", "worktrees", "archived_worktrees"]) {
      sqlite
        .prepare(`update or ignore ${table} set server_id = ? where server_id != ?`)
        .run(config.serverId, config.serverId)
      sqlite.prepare(`delete from ${table} where server_id != ?`).run(config.serverId)
    }
    sqlite
      .prepare(
        "insert into instance_meta (key, value) values ('adopted-server-id', ?) on conflict(key) do update set value = excluded.value"
      )
      .run(config.serverId)
  })()
}

const blockingDataUpgrades: ReadonlyArray<
  (sqlite: Database.Database, config: CodevisorDatabaseConfig) => void
> = [adoptServerIdentity, runCanonicalChatBackfill, runTranscriptStateUpgrade]

export const runBlockingDataUpgrades = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): void => {
  for (const upgrade of blockingDataUpgrades) upgrade(sqlite, config)
}
