import type { EventEnvelope, EventKind } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import { chatState } from "./chat-items.js"
import { cursorRows } from "./common-rows.js"
import { attempt } from "./errors.js"
import type { JsonRecord } from "./event-payloads.js"
import {
  isSessionShellEvent,
  withChatItemId,
  jsonRecord,
  payloadMarkdown
} from "./event-payloads.js"
import { insertSessionEvent, projectChatEvent } from "./event-projection.js"
import type { SessionEventRow } from "./event-rows.js"
import { canonicalUuid } from "./ids.js"
import { materializeNavigationDelta } from "./navigation-delta.js"
import { integer, rowReader } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { projectSessionAttention, projectSessionSidebarState } from "./session-attention.js"
import { linkSessionFiles } from "./session-files.js"
import { setupQuestionPresentation } from "./setup-questions.js"
import { projectSetupState } from "./setup-state.js"
import { readSyncBatch, trimSyncJournal, type SyncBatch } from "./sync-journal.js"
import { readToolSnapshot, transcriptTextResource } from "./transcript-bodies.js"
import { textPatchForEvent } from "./transcript-state.js"

export const makeEventsService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "appendEvent" | "latestEventCursor" | "readSyncBatch"> => {
  const { sqlite, config } = context

  const appendEvent = Effect.fn("CodevisorDatabase.appendEvent")(function* (
    kind: EventKind,
    rawSubjectId: string,
    payload: unknown
  ) {
    const subjectId = canonicalUuid(rawSubjectId)
    return yield* attempt("appendEvent", () => {
      const createdAt = isoTimestamp()
      return sqlite.transaction(() => {
        const event = newEvent(config.serverId, kind, subjectId, createdAt, payload)
        const sessionExists = isSession(sqlite, subjectId)
        const globalEventId = appendShellLogEvent(sqlite, event, sessionExists)
        projectSetupState(sqlite, subjectId, kind, globalEventId ?? 0, createdAt, payload)

        const logged = loggedEvent(event, globalEventId)
        const sessionEntry = appendSessionLogEvent(sqlite, logged, sessionExists)
        trimJournals(sqlite, logged, sessionEntry)
        return eventEnvelope(logged, sessionEntry)
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
          if (replaysNavigation(subjectId, batch)) return materializeNavigationDelta(context, batch)
          return batch
        })()
      ),
    latestEventCursor: attempt("latestEventCursor", () => latestCursor(sqlite))
  }
}

interface NewEvent {
  readonly serverId: string
  readonly kind: EventKind
  readonly subjectId: string
  readonly createdAt: string
  readonly payload: unknown
  readonly encoded: string
}

interface LoggedEvent extends NewEvent {
  readonly globalEventId: number | undefined
  readonly bytes: number
}

interface SessionLogEntry {
  readonly revision: number
  readonly chatItemId: string | undefined
  readonly deliveredPayload: unknown
  readonly bytes: number
}

const newEvent = (
  serverId: string,
  kind: EventKind,
  subjectId: string,
  createdAt: string,
  payload: unknown
): NewEvent => ({ serverId, kind, subjectId, createdAt, payload, encoded: JSON.stringify(payload) })

const loggedEvent = (event: NewEvent, globalEventId: number | undefined): LoggedEvent => ({
  ...event,
  globalEventId,
  bytes: Buffer.byteLength(event.encoded)
})

const appendShellLogEvent = (
  sqlite: ServiceContext["sqlite"],
  event: NewEvent,
  sessionExists: boolean
): number | undefined => {
  if (!belongsInShellLog(event, sessionExists)) return undefined
  return insertShellEvent(sqlite, event)
}

const belongsInShellLog = (event: NewEvent, sessionExists: boolean): boolean =>
  !sessionExists || isSessionShellEvent(event.kind, event.payload)

const appendSessionLogEvent = (
  sqlite: ServiceContext["sqlite"],
  event: LoggedEvent,
  sessionExists: boolean
): SessionLogEntry | undefined => {
  if (!sessionExists) return undefined

  const sessionEvent = insertSessionEvent(sqlite, sessionEventRow(event))
  const entry = deliverSessionEvent(sqlite, event, sessionEvent)
  projectSessionViews(sqlite, event, sessionEvent)
  return entry
}

const sessionEventRow = (event: LoggedEvent) => ({
  session_id: event.subjectId,
  global_event_id: event.globalEventId ?? null,
  server_id: event.serverId,
  kind: event.kind,
  created_at: event.createdAt,
  payload: event.encoded
})

const deliverSessionEvent = (
  sqlite: ServiceContext["sqlite"],
  event: LoggedEvent,
  sessionEvent: SessionEventRow
): SessionLogEntry => {
  const { revision } = sessionEvent
  const chatItemId = projectChatEvent(sqlite, sessionEvent)
  const deliveredPayload = materializeSessionDelivery(
    sqlite,
    event.subjectId,
    chatItemId,
    revision,
    event.payload
  )
  const bytes = storeDeliveredPayload(sqlite, event, revision, deliveredPayload)
  return { revision, chatItemId, deliveredPayload, bytes }
}

const storeDeliveredPayload = (
  sqlite: ServiceContext["sqlite"],
  event: LoggedEvent,
  revision: number,
  deliveredPayload: unknown
): number => {
  if (deliveredPayload === event.payload) return event.bytes

  const stored = JSON.stringify(deliveredPayload)
  sqlite.prepare(storeDeliveredPayloadSql).run(stored, event.subjectId, revision)
  return Buffer.byteLength(stored)
}

const projectSessionViews = (
  sqlite: ServiceContext["sqlite"],
  event: LoggedEvent,
  sessionEvent: SessionEventRow
): void => {
  projectSessionAttention(sqlite, sessionEvent)
  projectSessionSidebarState(sqlite, event.subjectId, event.createdAt)
  linkSessionFiles(sqlite, event.subjectId, event.encoded)
  if (event.kind === "session.output") touchSession(sqlite, event)
}

const trimJournals = (
  sqlite: ServiceContext["sqlite"],
  event: LoggedEvent,
  sessionEntry: SessionLogEntry | undefined
): void => {
  if (sessionEntry !== undefined) {
    trimSyncJournal(sqlite, sessionEntry.bytes, sessionEntry.revision, event.subjectId)
  }
  if (event.globalEventId !== undefined) trimSyncJournal(sqlite, event.bytes, event.globalEventId)
}

const eventEnvelope = (
  event: LoggedEvent,
  sessionEntry: SessionLogEntry | undefined
): EventEnvelope => {
  const { globalEventId } = event
  const subjectRevision = sessionEntry?.revision
  return {
    id: (globalEventId ?? subjectRevision)!,
    ...(globalEventId === undefined ? {} : { globalEventId }),
    ...(subjectRevision === undefined ? {} : { subjectRevision }),
    serverId: event.serverId,
    kind: event.kind,
    subjectId: event.subjectId,
    createdAt: event.createdAt,
    payload: withChatItemId(envelopePayload(event, sessionEntry), sessionEntry?.chatItemId ?? null)
  }
}

const envelopePayload = (event: NewEvent, sessionEntry: SessionLogEntry | undefined): unknown =>
  sessionEntry === undefined ? event.payload : sessionEntry.deliveredPayload

const replaysNavigation = (subjectId: string | undefined, batch: SyncBatch): boolean =>
  subjectId === undefined && !batch.requiresSnapshot

const materializeSessionDelivery = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  chatItemId: string | undefined,
  subjectRevision: number,
  payload: unknown
): unknown => {
  let deliveredPayload = payload
  const update = jsonRecord(payload)
  if (chatItemId !== undefined && update !== undefined) {
    deliveredPayload = textPatchForEvent(sqlite, chatItemId, subjectRevision, update) ?? payload
  }
  if (
    chatItemId !== undefined &&
    typeof update?.toolCallId === "string" &&
    (update.sessionUpdate === "tool_call" || update.sessionUpdate === "tool_call_update")
  ) {
    deliveredPayload = readToolSnapshot(sqlite, chatItemId, update.toolCallId)!
  }
  if (
    chatItemId !== undefined &&
    update?.sessionUpdate === "question_resolved" &&
    typeof update.questionId === "string"
  ) {
    const resolution = questionResolutionDelivery(sqlite, chatItemId, update, update.questionId)
    deliveredPayload = withSetupContinuation(sqlite, sessionId, chatItemId, resolution)
  }
  if (chatItemId !== undefined && update?.sessionUpdate === "plan_document") {
    deliveredPayload = planDocumentDelivery(sqlite, chatItemId, subjectRevision, update)
  }
  if (chatItemId !== undefined && update?.role === "user" && update.startsTurn !== true) {
    deliveredPayload = steeredMessageDelivery(sqlite, sessionId, update)
  }
  return deliveredPayload
}

const questionResolutionDelivery = (
  sqlite: ServiceContext["sqlite"],
  chatItemId: string,
  update: JsonRecord,
  questionId: string
): JsonRecord => {
  const statePosition = questionResolvedPosition(sqlite, chatItemId, questionId)
  return { ...update, statePosition }
}

const withSetupContinuation = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  questionItemId: string,
  resolution: JsonRecord
): JsonRecord => {
  if (setupQuestionPresentation(resolution) === undefined) return resolution

  const continuation = chatState(sqlite, sessionId).current_item_id
  if (continuation === null || continuation === questionItemId) return resolution

  return { ...resolution, assistantItemId: continuation }
}

const planDocumentDelivery = (
  sqlite: ServiceContext["sqlite"],
  chatItemId: string,
  subjectRevision: number,
  update: JsonRecord
): JsonRecord => {
  return {
    ...update,
    markdown: (payloadMarkdown(update) ?? "").slice(0, 24_000),
    stateRevision: subjectRevision,
    detailResource: transcriptTextResource(sqlite, chatItemId, "plan")
  }
}

const steeredMessageDelivery = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  update: JsonRecord
): JsonRecord => {
  const assistantItemId = chatState(sqlite, sessionId).current_item_id
  return assistantItemId === null ? update : { ...update, assistantItemId }
}

const isSession = (sqlite: ServiceContext["sqlite"], subjectId: string): boolean =>
  sqlite.prepare(sessionExistsSql).get(subjectId) !== undefined

const insertShellEvent = (sqlite: ServiceContext["sqlite"], event: NewEvent): number =>
  Number(
    sqlite
      .prepare(insertEventSql)
      .run(event.serverId, event.kind, event.subjectId, event.createdAt, event.encoded)
      .lastInsertRowid
  )

const touchSession = (sqlite: ServiceContext["sqlite"], event: NewEvent): void => {
  sqlite.prepare(touchSessionSql).run(event.createdAt, event.subjectId)
}

const questionResolvedPosition = (
  sqlite: ServiceContext["sqlite"],
  chatItemId: string,
  questionId: string
): number =>
  entryPositionRows.one(
    sqlite.prepare(entryPositionSql).get(chatItemId, `question_resolved:${questionId}`)
  ).position

const latestCursor = (sqlite: ServiceContext["sqlite"]): number =>
  cursorRows.one(sqlite.prepare(latestCursorSql).get()).cursor

const entryPositionRows = rowReader({ position: integer })

const sessionExistsSql = "select 1 from sessions where id = ?"

const insertEventSql =
  "insert into events (server_id, kind, subject_id, created_at, payload) values (?, ?, ?, ?, ?)"

const storeDeliveredPayloadSql =
  "update session_events set payload = ? where session_id = ? and revision = ?"

const touchSessionSql = "update sessions set updated_at = ? where id = ?"

const entryPositionSql =
  "select position from transcript_entries where item_id = ? and entry_key = ?"

const latestCursorSql =
  "select max(coalesce((select max(id) from events), 0), coalesce((select floor from sync_watermarks where subject_id = 'global'), 0)) as cursor"
