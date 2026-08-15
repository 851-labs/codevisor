import { isoTimestamp } from "@codevisor/api"
import {
  chatAssistantSummary,
  chatRoute,
  createChatItem,
  finishAssistantChatItem,
  sessionGoalSnapshot,
  setChatRoute
} from "./chat-items.js"
import { attempt } from "./errors.js"
import { backgroundTasksFromRaw, pendingQuestionFromRaw } from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import {
  conversationFromRow,
  listPromptQueueSync,
  sessionEventFromRow,
  transcriptFromChatRow
} from "./row-mappers.js"
import type { ChatItemRow, ConversationRow, SessionActionRow, SessionEventRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

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
  | "appendConversationItem"
  | "hasConversationMessage"
  | "hasTerminalAssistantAfterMessage"
  | "failStaleAssistantChatItems"
  | "getSessionActionResult"
  | "saveSessionActionResult"
> => {
  const { sqlite, getSession } = context

  return {
    getSessionDetail: (rawId) =>
      attempt("getSessionDetail", () => {
        const id = canonicalUuid(rawId)
        const session = getSession(id)
        const state = sqlite
          .prepare(
            "select revision as cursor, pending_question, background_tasks from sessions where id = ?"
          )
          .get(id) as {
          readonly cursor: number
          readonly pending_question: string | null
          readonly background_tasks: string
        }
        const pendingQuestion = pendingQuestionFromRaw(state.pending_question)
        const backgroundTasks = backgroundTasksFromRaw(state.background_tasks)
        const goal = sessionGoalSnapshot(sqlite, id)
        return {
          session,
          conversation: sqlite
            .prepare(
              `select chat_items.id, chat_items.role, chat_items.message_id,
                 coalesce((select text from chat_parts
                   where item_id = chat_items.id and kind = 'text' order by position limit 1), '') as text,
                 chat_items.created_at, case when chat_items.status = 'streaming' then 1 else 0 end as is_generating,
                 chat_items.attachments
               from chat_items
               where session_id = ? and ${renderableChatItemPredicate}
               order by position asc`
            )
            .all(id)
            .map((row) => conversationFromRow(row as ConversationRow)),
          promptQueue: listPromptQueueSync(sqlite, id),
          eventCursor: Number(state.cursor),
          ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
          pendingPlanApproval: session.pendingPlanApproval === true,
          backgroundTasks,
          ...(goal === undefined ? {} : { goal })
        }
      }),
    getTranscriptPage: (rawSessionId, before, limit) =>
      attempt("getTranscriptPage", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const session = getSession(sessionId)
        const bounded = Math.max(1, Math.min(64, Math.trunc(limit)))
        const rows = sqlite
          .prepare(
            `select chat_items.*,
               coalesce((select text from chat_parts
                 where item_id = chat_items.id and kind = 'text' order by position limit 1), '') as text,
               (select text from chat_parts
                 where item_id = chat_items.id and kind = 'plan' order by position limit 1) as plan_document
             from chat_items
             where session_id = ? and role in ('user', 'assistant')
               and ${renderableChatItemPredicate}
               and (? is null or position < ?)
             order by position desc limit ?`
          )
          .all(sessionId, before ?? null, before ?? null, bounded + 1) as ReadonlyArray<ChatItemRow>
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
        const hasMore = rows.length > pageRows.length
        const items = [...pageRows].reverse().map((row) => {
          const item = transcriptFromChatRow(row)
          if (row.role !== "assistant" || row.status !== "streaming") return item
          const summary = chatAssistantSummary(sqlite, sessionId, row.id)
          return {
            ...item,
            text: summary.text,
            ...(summary.planDocument === undefined ? {} : { planDocument: summary.planDocument }),
            ...(summary.messageId === undefined ? {} : { messageId: summary.messageId })
          }
        })
        const cursor = pageRows.at(-1)?.position
        const state = sqlite
          .prepare(
            "select revision as cursor, pending_question, background_tasks from sessions where id = ?"
          )
          .get(sessionId) as {
          readonly cursor: number
          readonly pending_question: string | null
          readonly background_tasks: string
        }
        const pendingQuestion = pendingQuestionFromRaw(state.pending_question)
        const backgroundTasks = backgroundTasksFromRaw(state.background_tasks)
        const goal = sessionGoalSnapshot(sqlite, sessionId)
        return {
          items,
          ...(hasMore ? { nextBefore: String(cursor!) } : {}),
          hasMore,
          eventCursor: Number(state.cursor),
          ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
          pendingPlanApproval: session.pendingPlanApproval === true,
          backgroundTasks,
          ...(goal === undefined ? {} : { goal }),
          usage: session.usage
        }
      }),
    getTranscriptItemDetails: (rawSessionId, itemId) =>
      attempt("getTranscriptItemDetails", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const item = sqlite
          .prepare("select revision from chat_items where session_id = ? and id = ?")
          .get(sessionId, itemId) as { revision: number } | undefined
        if (item === undefined) return undefined
        const events = (
          sqlite
            .prepare(
              `select * from session_events
               where session_id = ? and chat_item_id = ? order by revision asc`
            )
            .all(sessionId, itemId) as ReadonlyArray<SessionEventRow>
        ).map(sessionEventFromRow)
        return { itemId, revision: item.revision, events }
      }),
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
            sqlite
              .prepare(
                `update chat_parts set text = coalesce(text, '') || ?, revision = revision + 1
                 where item_id = ? and kind = 'text'`
              )
              .run(text, routed)
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
    failStaleAssistantChatItems: (rawSessionId, stopDetail, excludeItemId) =>
      attempt("failStaleAssistantChatItems", () => {
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
            finishAssistantChatItem(
              sqlite,
              sessionId,
              row.id,
              now,
              "interrupted",
              stopDetail,
              false,
              true
            )
          }
          // A failed row can never be the projection's write target again; a
          // pointer left on one would resurrect it on the next assistant event.
          sqlite
            .prepare(
              `update session_chat_state set current_item_id = null
               where session_id = ? and current_item_id in (
                 select id from chat_items where session_id = ? and status = 'failed'
               )`
            )
            .run(sessionId, sessionId)
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
}
