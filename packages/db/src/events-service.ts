import type { EventKind } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"
import { attempt } from "./errors.js"
import { isSessionShellEvent, withChatItemId } from "./event-payloads.js"
import { insertSessionEvent, projectChatEvent } from "./event-projection.js"
import { canonicalUuid } from "./ids.js"
import { eventFromRow, sessionEventFromRow } from "./row-mappers.js"
import type { EventRow, SessionEventRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"
import { projectSessionAttention, projectSessionSidebarState } from "./session-attention.js"

export const makeEventsService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  "appendEvent" | "latestEventCursor" | "listEvents" | "listSubjectEvents"
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
        let subjectRevision: number | undefined
        let chatItemId: string | undefined
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
          projectSessionAttention(sqlite, sessionEvent)
          projectSessionSidebarState(sqlite, subjectId, createdAt)
          if (kind === "session.output") {
            sqlite
              .prepare("update sessions set updated_at = ? where id = ?")
              .run(createdAt, subjectId)
          }
        }
        return {
          id: (globalEventId ?? subjectRevision)!,
          ...(globalEventId === undefined ? {} : { globalEventId }),
          ...(subjectRevision === undefined ? {} : { subjectRevision }),
          serverId: config.serverId,
          kind,
          subjectId,
          createdAt,
          payload: withChatItemId(payload, chatItemId ?? null)
        }
      })()
    })
  })

  return {
    appendEvent,
    latestEventCursor: attempt("latestEventCursor", () => {
      const row = sqlite.prepare("select coalesce(max(id), 0) as cursor from events").get() as {
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
