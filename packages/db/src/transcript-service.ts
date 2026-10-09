import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import { chatRoute, createChatItem, finishAssistantChatItem, setChatRoute } from "./chat-items.js"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { listPromptQueueSync } from "./row-mappers.js"
import type { SessionActionRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { readTranscriptBodyPage } from "./transcript-bodies.js"
import { readTranscriptPage } from "./transcript-pages.js"
import { readTranscriptStatePage } from "./transcript-state-pages.js"
import { appendTranscriptText, readTranscriptText } from "./transcript-state.js"

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
  | "closeStaleAssistantChatItems"
  | "listQuietStreamingSessions"
  | "getSessionActionResult"
  | "saveSessionActionResult"
> => {
  const { sqlite, getSession } = context

  const service: Pick<
    CodevisorDatabaseService,
    | "getSessionDetail"
    | "getTranscriptPage"
    | "getTranscriptItemDetails"
    | "getTranscriptBodyPage"
    | "appendConversationItem"
    | "hasConversationMessage"
    | "hasTerminalAssistantAfterMessage"
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
          return readTranscriptPage(sqlite, sessionId, session, rawBefore, limit, forward)
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
    closeStaleAssistantChatItems: (rawSessionId, excludeItemId) =>
      attempt("closeStaleAssistantChatItems", () => {
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
          for (const row of stale) {
            finishAssistantChatItem(sqlite, sessionId, row.id, now, "end_turn")
          }
          // A finished row can never be the write target again; a pointer
          // left on one would resurrect it on the next assistant event.
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
      }),
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
