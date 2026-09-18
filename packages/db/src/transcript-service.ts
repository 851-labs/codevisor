import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import {
  chatAssistantSummary,
  chatRoute,
  createChatItem,
  finishAssistantChatItem,
  sessionGoalSnapshot,
  setChatRoute
} from "./chat-items.js"
import { attempt } from "./errors.js"
import {
  backgroundTasksFromRaw,
  pendingQuestionFromRaw,
  sessionPlanFromRaw
} from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import { listPromptQueueSync, transcriptFromChatRow } from "./row-mappers.js"
import type { ChatItemRow, SessionActionRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { sessionSetupState } from "./setup-state.js"
import { transcriptTextResource } from "./transcript-bodies.js"
import { readTranscriptBodyPage } from "./transcript-bodies.js"
import { readTranscriptStatePage } from "./transcript-state-pages.js"
import { appendTranscriptText, readTranscriptText } from "./transcript-state.js"

// Turn-boundary events can legitimately leave behind completed item shells
// when a harness emits no user payload or assistant output. They are useful to
// the event projector, but they are not transcript rows: returning them makes
// virtualized clients reserve estimated height for content that cannot render.
// Keep streaming shells (the live "waiting for the agent" row) and every form
// of semantic content supported by the transcript API.
const renderableChatItemPredicate = `(
  chat_items.status = 'streaming'
  or chat_items.has_details = 1
  or length(coalesce(chat_items.stop_reason, '')) > 0
  or length(coalesce(chat_items.stop_detail, '')) > 0
  or (chat_items.attachments is not null and chat_items.attachments != '[]')
  or exists (
    select 1 from chat_parts as renderable_part
    where renderable_part.item_id = chat_items.id
      and length(coalesce(renderable_part.text, '')) > 0
  )
)`

// A row count is not a render-cost bound: one assistant item can contain a
// 20k-character essay. Keep reverse pages small enough for clients to parse
// and lay out without a visible hitch, while always returning at least the
// newest row so a single oversized answer can still be reached.
const maxInitialTranscriptPageCharacters = 24_000
const maxOlderTranscriptPageCharacters = 64_000

export const makeTranscriptService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "getSessionDetail"
  | "getTranscriptPage"
  | "getTranscriptItemDetails"
  | "getTranscriptBodyPage"
  | "appendConversationItem"
  | "hasConversationMessage"
  | "hasTerminalAssistantAfterMessage"
  | "failStaleAssistantChatItems"
  | "closeStaleAssistantChatItems"
  | "listQuietStreamingSessions"
  | "getSessionActionResult"
  | "saveSessionActionResult"
> => {
  const { sqlite, getSession } = context

  /// Shared body of the two stale-row settlers: every still-streaming
  /// assistant row (except `excludeItemId`) is finished by `finish`, and the
  /// projection's write pointer is dropped from any row it settled — a
  /// finished row can never be the write target again; a pointer left on
  /// one would resurrect it on the next assistant event.
  const settleStaleAssistantChatItems = (
    rawSessionId: string,
    excludeItemId: string | undefined,
    finish: (sessionId: string, itemId: string, now: string) => void
  ): number => {
    const sessionId = canonicalUuid(rawSessionId)
    getSession(sessionId)
    return sqlite.transaction(() => {
      const stale = sqlite
        .prepare(
          `select id from chat_items
           where session_id = ? and role = 'assistant' and status = 'streaming' and id != ?
           order by position asc`
        )
        .all(sessionId, excludeItemId ?? "") as Array<{ id: string }>
      const now = isoTimestamp()
      for (const row of stale) finish(sessionId, row.id, now)
      if (stale.length > 0) {
        sqlite
          .prepare(
            `update session_chat_state set current_item_id = null
             where session_id = ? and current_item_id in (${stale.map(() => "?").join(", ")})`
          )
          .run(sessionId, ...stale.map((row) => row.id))
      }
      return stale.length
    })()
  }

  const service: Pick<
    CodevisorDatabaseService,
    | "getSessionDetail"
    | "getTranscriptPage"
    | "getTranscriptItemDetails"
    | "getTranscriptBodyPage"
    | "appendConversationItem"
    | "hasConversationMessage"
    | "hasTerminalAssistantAfterMessage"
    | "failStaleAssistantChatItems"
    | "closeStaleAssistantChatItems"
    | "listQuietStreamingSessions"
    | "getSessionActionResult"
    | "saveSessionActionResult"
  > = {
    getSessionDetail: (rawId) =>
      Effect.map(service.getTranscriptPage(rawId, undefined, 8), (page) => ({
        ...page,
        session: getSession(canonicalUuid(rawId)),
        conversation: page.items.map((item) => ({
          id: item.id,
          role: item.role,
          messageId: item.messageId,
          text: item.text,
          createdAt: item.createdAt,
          isGenerating: item.isGenerating,
          attachments: item.attachments
        })),
        promptQueue: listPromptQueueSync(sqlite, canonicalUuid(rawId))
      })),
    getTranscriptPage: (rawSessionId, rawBefore, limit, forward = false) =>
      attempt("getTranscriptPage", () =>
        sqlite.transaction(() => {
          const sessionId = canonicalUuid(rawSessionId)
          const session = getSession(sessionId)
          const before =
            typeof rawBefore === "string"
              ? (
                  sqlite
                    .prepare(
                      "select position from chat_items where session_id = ? and (id = ? or lower(message_id) = ?)"
                    )
                    .get(sessionId, canonicalUuid(rawBefore), canonicalUuid(rawBefore)) as
                    | { position: number }
                    | undefined
                )?.position
              : rawBefore
          if (rawBefore !== undefined && before === undefined)
            throw new Error("Transcript cursor item no longer exists")
          const bounded = Math.max(1, Math.min(64, Math.trunc(limit)))
          const rows = sqlite
            .prepare(
              `select chat_items.*,
               coalesce((select substr(text, 1, 24000) from chat_parts
                 where item_id = chat_items.id and kind = 'text' order by position limit 1), '') as text,
               (select substr(text, 1, 24000) from chat_parts
                 where item_id = chat_items.id and kind = 'plan' order by position limit 1) as plan_document
             from chat_items
             where session_id = ? and role in ('user', 'assistant')
               and ${renderableChatItemPredicate}
               and (? is null or position ${forward ? ">" : "<"} ?)
             order by position ${forward ? "asc" : "desc"} limit ?`
            )
            .all(
              sessionId,
              before ?? null,
              before ?? null,
              bounded + 1
            ) as ReadonlyArray<ChatItemRow>
          const candidates = rows.slice(0, bounded)
          const pageRows: ChatItemRow[] = []
          let characters = 0
          const maxCharacters =
            bounded <= 8 ? maxInitialTranscriptPageCharacters : maxOlderTranscriptPageCharacters
          for (const row of candidates) {
            const rowCharacters = row.text.length + (row.plan_document?.length ?? 0)
            if (pageRows.length > 0 && characters + rowCharacters > maxCharacters) {
              break
            }
            pageRows.push(row)
            characters += rowCharacters
          }
          const ordered = forward ? pageRows : [...pageRows].reverse()
          const items = ordered.map((row) => {
            const item = transcriptFromChatRow(row)
            if (row.role !== "assistant") {
              const entry = sqlite
                .prepare(
                  "select entry_key from transcript_entries where item_id = ? and category = 'text' order by position limit 1"
                )
                .get(row.id) as { entry_key: string } | undefined
              return {
                ...item,
                ...(entry === undefined
                  ? {}
                  : { textResource: transcriptTextResource(sqlite, row.id, entry.entry_key) })
              }
            }
            const summary = chatAssistantSummary(sqlite, sessionId, row.id)
            return {
              ...item,
              text: summary.text,
              textResource: summary.textResource,
              planResource: summary.planResource,
              textGeneration: summary.textGeneration,
              textRevision: summary.textRevision,
              textPosition: summary.textPosition,
              ...(summary.planDocument === undefined ? {} : { planDocument: summary.planDocument }),
              ...(summary.messageId === undefined ? {} : { messageId: summary.messageId }),
              ...(summary.phase === undefined ? {} : { phase: summary.phase })
            }
          })
          const first = ordered[0]?.position
          const last = ordered.at(-1)?.position
          const hasMore =
            first !== undefined &&
            sqlite
              .prepare(
                `select 1 from chat_items where session_id = ?
          and ${renderableChatItemPredicate} and position < ? limit 1`
              )
              .get(sessionId, first) !== undefined
          const hasNewer =
            last !== undefined &&
            sqlite
              .prepare(
                `select 1 from chat_items where session_id = ?
          and ${renderableChatItemPredicate} and position > ? limit 1`
              )
              .get(sessionId, last) !== undefined
          const state = sqlite
            .prepare(
              `select revision as cursor, pending_question, background_tasks, session_plan
             from sessions where id = ?`
            )
            .get(sessionId) as {
            readonly cursor: number
            readonly pending_question: string | null
            readonly background_tasks: string
            readonly session_plan: string | null
          }
          const pendingQuestion = pendingQuestionFromRaw(state.pending_question)
          const backgroundTasks = backgroundTasksFromRaw(state.background_tasks)
          const sessionPlan = sessionPlanFromRaw(state.session_plan)
          const goal = sessionGoalSnapshot(sqlite, sessionId)
          return {
            items,
            setupActivities: sessionSetupState(sqlite, sessionId),
            ...(hasMore ? { nextBefore: String(first!) } : {}),
            ...(last === undefined ? {} : { nextAfter: `after:${last}` }),
            hasNewer,
            hasMore,
            eventCursor: Number(state.cursor),
            stateUpdates: (
              sqlite
                .prepare(
                  `select payload from session_state where session_id = ?
            and state_key in ('available_commands_update', 'config_option_update', 'current_mode_update')`
                )
                .all(sessionId) as Array<{ payload: string }>
            ).map((row) => JSON.parse(row.payload) as unknown),
            ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
            pendingPlanApproval: session.pendingPlanApproval === true,
            backgroundTasks,
            ...(goal === undefined ? {} : { goal }),
            ...(sessionPlan === undefined ? {} : { sessionPlan }),
            usage: session.usage
          }
        })()
      ),
    getTranscriptItemDetails: (rawSessionId, itemId, after) =>
      attempt("getTranscriptItemDetails", () =>
        readTranscriptStatePage(sqlite, canonicalUuid(rawSessionId), itemId, after)
      ),
    getTranscriptBodyPage: (sessionId, itemId, key, field, position) =>
      attempt("getTranscriptBodyPage", () =>
        readTranscriptBodyPage(sqlite, canonicalUuid(sessionId), itemId, key, field, position)
      ),
    appendConversationItem: (rawSessionId, role, messageId, text, isGenerating, attachments) =>
      attempt("appendConversationItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const now = isoTimestamp()
        // Streamed messages arrive as token-sized chunks sharing a messageId.
        // Extend the newest item in place when the chunk continues it —
        // materializing one row per token grew a single answer into
        // thousands of rows, bloating the store and making session opens
        // replay-heavy. Coalescing needs a provable same-span signal, so
        // rows without a messageId (and attachment-bearing rows) still
        // insert normally.
        sqlite.transaction(() => {
          const routeKey = messageId === undefined ? undefined : `message:${role}:${messageId}`
          const routed = routeKey === undefined ? undefined : chatRoute(sqlite, sessionId, routeKey)
          const last = sqlite
            .prepare(
              "select id from chat_items where session_id = ? order by position desc limit 1"
            )
            .get(sessionId) as { id: string } | undefined
          if (
            routed !== undefined &&
            routed === last?.id &&
            (attachments === undefined || attachments.length === 0)
          ) {
            const key = `message::${messageId}`
            appendTranscriptText(sqlite, routed, key, text)
            sqlite
              .prepare(
                "update chat_parts set text = ?, revision = revision + 1 where item_id = ? and kind = 'text'"
              )
              .run(readTranscriptText(sqlite, routed, key, 24_000), routed)
            sqlite
              .prepare(
                "update chat_items set status = ?, updated_at = ?, revision = revision + 1 where id = ?"
              )
              .run(isGenerating ? "streaming" : "complete", now, routed)
          } else {
            const itemId = createChatItem(sqlite, sessionId, role, now, {
              text,
              ...(messageId === undefined ? {} : { messageId }),
              status: isGenerating ? "streaming" : "complete",
              ...(attachments === undefined ? {} : { attachments })
            })
            if (routeKey !== undefined && (attachments === undefined || attachments.length === 0)) {
              setChatRoute(sqlite, sessionId, routeKey, itemId)
            }
          }
          sqlite.prepare("update sessions set updated_at = ? where id = ?").run(now, sessionId)
        })()
      }),
    hasConversationMessage: (sessionId, messageId) =>
      attempt("hasConversationMessage", () =>
        Boolean(
          sqlite
            .prepare("select 1 from chat_items where session_id = ? and message_id = ? limit 1")
            .get(canonicalUuid(sessionId), messageId)
        )
      ),
    hasTerminalAssistantAfterMessage: (sessionId, messageId) =>
      attempt("hasTerminalAssistantAfterMessage", () =>
        Boolean(
          sqlite
            .prepare(
              `select 1
               from chat_items as input
               join chat_items as answer
                 on answer.session_id = input.session_id
                and answer.position > input.position
                and answer.role = 'assistant'
                and answer.status != 'streaming'
               where input.session_id = ? and input.message_id = ?
               limit 1`
            )
            .get(canonicalUuid(sessionId), messageId)
        )
      ),
    listQuietStreamingSessions: (quietSinceIso) =>
      attempt("listQuietStreamingSessions", () =>
        (
          sqlite
            .prepare(
              // Activity belongs to current state, independent of journal retention.
              `select distinct item.session_id from chat_items as item join sessions on sessions.id = item.session_id
               where item.role = 'assistant' and item.status = 'streaming'
                 and coalesce(sessions.last_event_at, sessions.created_at) <= ?`
            )
            .all(quietSinceIso) as Array<{ session_id: string }>
        ).map((row) => row.session_id)
      ),
    failStaleAssistantChatItems: (rawSessionId, stopDetail, excludeItemId) =>
      attempt("failStaleAssistantChatItems", () =>
        settleStaleAssistantChatItems(rawSessionId, excludeItemId, (sessionId, itemId, now) =>
          finishAssistantChatItem(
            sqlite,
            sessionId,
            itemId,
            now,
            "interrupted",
            stopDetail,
            undefined,
            false,
            true
          )
        )
      ),
    closeStaleAssistantChatItems: (rawSessionId, excludeItemId) =>
      attempt("closeStaleAssistantChatItems", () =>
        settleStaleAssistantChatItems(rawSessionId, excludeItemId, (sessionId, itemId, now) =>
          finishAssistantChatItem(sqlite, sessionId, itemId, now, "end_turn")
        )
      ),
    getSessionActionResult: (sessionId, clientActionId) =>
      attempt("getSessionActionResult", () => {
        const row = sqlite
          .prepare("select * from session_actions where session_id = ? and client_action_id = ?")
          .get(canonicalUuid(sessionId), clientActionId) as SessionActionRow | undefined
        return row === undefined ? undefined : (JSON.parse(row.response) as unknown)
      }),
    saveSessionActionResult: (sessionId, clientActionId, actionKind, response) =>
      attempt("saveSessionActionResult", () => {
        sqlite
          .prepare(
            `insert into session_actions (
              session_id, client_action_id, action_kind, response, created_at
            ) values (?, ?, ?, ?, ?)
            on conflict(session_id, client_action_id) do nothing`
          )
          .run(
            canonicalUuid(sessionId),
            clientActionId,
            actionKind,
            JSON.stringify(response),
            isoTimestamp()
          )
      })
  }
  return service
}
