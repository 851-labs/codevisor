import type { EventKind } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import { attempt } from "./errors.js"
import { isSessionShellEvent, withChatItemId, jsonRecord } from "./event-payloads.js"
import { insertSessionEvent, projectChatEvent } from "./event-projection.js"
import { canonicalUuid } from "./ids.js"
import { materializeNavigationDelta } from "./navigation-delta.js"
import { eventFromRow, sessionEventFromRow } from "./row-mappers.js"
import type { EventRow, SessionEventRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { projectSessionAttention, projectSessionSidebarState } from "./session-attention.js"
import { projectSetupState } from "./setup-state.js"
import { readSyncBatch, trimSyncJournal } from "./sync-journal.js"
import { readToolSnapshot, transcriptTextResource } from "./transcript-bodies.js"
import { textPatchForEvent } from "./transcript-state.js"

export const makeEventsService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  "appendEvent" | "latestEventCursor" | "listEvents" | "listSubjectEvents" | "readSyncBatch"
> => {
  const { sqlite, config } = context

  const appendEvent = Effect.fn("CodevisorDatabase.appendEvent")(function* (
    kind: EventKind,
    rawSubjectId: string,
    payload: unknown
  ) {
    // Subjects are usually uuid resource ids (sessions, projects); harness
    // ids and other non-uuid subjects pass through canonicalUuid untouched.
    const subjectId = canonicalUuid(rawSubjectId)
    return yield* attempt("appendEvent", () => {
      const createdAt = isoTimestamp()
      return sqlite.transaction(() => {
        const encoded = JSON.stringify(payload)
        const sessionExists =
          sqlite.prepare("select 1 from sessions where id = ?").get(subjectId) !== undefined
        const belongsInShellLog = !sessionExists || isSessionShellEvent(kind, payload)
        const globalEventId = belongsInShellLog
          ? Number(
              sqlite
                .prepare(
                  "insert into events (server_id, kind, subject_id, created_at, payload) values (?, ?, ?, ?, ?)"
                )
                .run(config.serverId, kind, subjectId, createdAt, encoded).lastInsertRowid
            )
          : undefined
        projectSetupState(sqlite, subjectId, kind, globalEventId ?? 0, createdAt, payload)
        let subjectRevision: number | undefined
        let chatItemId: string | undefined
        let deliveredPayload = payload
        let sessionBytes = Buffer.byteLength(encoded)
        if (sessionExists) {
          const sessionEvent = insertSessionEvent(sqlite, {
            session_id: subjectId,
            global_event_id: globalEventId ?? null,
            server_id: config.serverId,
            kind,
            created_at: createdAt,
            payload: encoded
          })
          subjectRevision = sessionEvent.revision
          chatItemId = projectChatEvent(sqlite, sessionEvent)
          const update = jsonRecord(payload)
          if (chatItemId !== undefined && update !== undefined) {
            deliveredPayload =
              textPatchForEvent(sqlite, chatItemId, subjectRevision, update) ?? payload
          }
          if (
            chatItemId !== undefined &&
            typeof update?.toolCallId === "string" &&
            (update.sessionUpdate === "tool_call" || update.sessionUpdate === "tool_call_update")
          ) {
            deliveredPayload = readToolSnapshot(sqlite, chatItemId, update.toolCallId)!
          }
          if (chatItemId !== undefined && update?.sessionUpdate === "plan_document") {
            deliveredPayload = {
              ...update,
              markdown: String(update.markdown ?? "").slice(0, 24_000),
              stateRevision: subjectRevision,
              detailResource: transcriptTextResource(sqlite, chatItemId, "plan")
            }
          }
          if (deliveredPayload !== payload) {
            const state = JSON.stringify(deliveredPayload)
            sqlite
              .prepare(
                "update session_events set payload = ? where session_id = ? and revision = ?"
              )
              .run(state, subjectId, subjectRevision)
            sessionBytes = Buffer.byteLength(state)
          }
          projectSessionAttention(sqlite, sessionEvent, config.attentionSettleGraceMs)
          projectSessionSidebarState(sqlite, subjectId, createdAt)
          if (kind === "session.output") {
            sqlite
              .prepare("update sessions set updated_at = ? where id = ?")
              .run(createdAt, subjectId)
          }
        }
        const bytes = Buffer.byteLength(encoded)
        if (subjectRevision !== undefined)
          trimSyncJournal(sqlite, sessionBytes, subjectRevision, subjectId)
        if (globalEventId !== undefined) trimSyncJournal(sqlite, bytes, globalEventId)
        return {
          id: (globalEventId ?? subjectRevision)!,
          ...(globalEventId === undefined ? {} : { globalEventId }),
          ...(subjectRevision === undefined ? {} : { subjectRevision }),
          serverId: config.serverId,
          kind,
          subjectId,
          createdAt,
          payload: withChatItemId(deliveredPayload, chatItemId ?? null)
        }
      })()
    })
  })

  return {
    appendEvent,
    readSyncBatch: (since, subjectId) =>
      attempt("readSyncBatch", () =>
        sqlite.transaction(() => {
          const batch = readSyncBatch(
            sqlite,
            since,
            subjectId === undefined ? undefined : canonicalUuid(subjectId)
          )
          return subjectId === undefined && !batch.requiresSnapshot
            ? materializeNavigationDelta(context, batch)
            : batch
        })()
      ),
    latestEventCursor: attempt("latestEventCursor", () => {
      const row = sqlite
        .prepare(
          "select max(coalesce((select max(id) from events), 0), coalesce((select floor from sync_watermarks where subject_id = 'global'), 0)) as cursor"
        )
        .get() as {
        readonly cursor: number
      }
      return row.cursor
    }),
    listEvents: (since) =>
      attempt("listEvents", () =>
        sqlite
          .prepare("select * from events where id > ? order by id asc")
          .all(since)
          .map((row) => eventFromRow(row as EventRow))
      ),
    listSubjectEvents: (rawSubjectId, since = 0) =>
      attempt("listSubjectEvents", () => {
        const subjectId = canonicalUuid(rawSubjectId)
        const isSession =
          sqlite.prepare("select 1 from sessions where id = ?").get(subjectId) !== undefined
        return isSession
          ? sqlite
              .prepare(
                `select * from session_events
                 where session_id = ? and revision > ? order by revision asc`
              )
              .all(subjectId, since)
              .map((row) => sessionEventFromRow(row as SessionEventRow))
          : sqlite
              .prepare("select * from events where subject_id = ? and id > ? order by id asc")
              .all(subjectId, since)
              .map((row) => eventFromRow(row as EventRow))
      })
  }
}
