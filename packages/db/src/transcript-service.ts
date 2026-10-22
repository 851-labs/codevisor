import type { AttachmentRef } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import { chatRoute, createChatItem, finishAssistantChatItem, setChatRoute } from "./chat-items.js"
import { idRows } from "./common-rows.js"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { listPromptQueueSync } from "./row-mappers.js"
import { rowReader, text as textColumn } from "./row-reader.js"
import { sessionActionRows } from "./rows.js"
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
        const message: ConversationMessage = {
          sessionId: canonicalUuid(rawSessionId),
          now: isoTimestamp(),
          role,
          messageId,
          text,
          isGenerating,
          attachments
        }
        sqlite.transaction(() => appendConversationMessage(sqlite, message))()
      }),
    hasConversationMessage: (sessionId, messageId) =>
      attempt("hasConversationMessage", () => hasMessage(sqlite, sessionId, messageId)),
    hasTerminalAssistantAfterMessage: (sessionId, messageId) =>
      attempt("hasTerminalAssistantAfterMessage", () =>
        hasAnswerAfterMessage(sqlite, sessionId, messageId)
      ),
    listQuietStreamingSessions: (quietSinceIso) =>
      attempt("listQuietStreamingSessions", () => quietStreamingSessionIds(sqlite, quietSinceIso)),
    closeStaleAssistantChatItems: (rawSessionId, excludeItemId) =>
      attempt("closeStaleAssistantChatItems", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return sqlite.transaction(() => {
          const stale = staleStreamingAssistantIds(sqlite, sessionId, excludeItemId)
          const now = isoTimestamp()
          for (const itemId of stale) {
            finishAssistantChatItem(sqlite, sessionId, itemId, now, "end_turn")
          }
          if (stale.length > 0) clearCurrentItemAmong(sqlite, sessionId, stale)
          return stale.length
        })()
      }),
    getSessionActionResult: (sessionId, clientActionId) =>
      attempt("getSessionActionResult", () => {
        const response = savedActionResponse(sqlite, sessionId, clientActionId)
        return response === undefined ? undefined : (JSON.parse(response) as unknown)
      }),
    saveSessionActionResult: (sessionId, clientActionId, actionKind, response) =>
      attempt("saveSessionActionResult", () => {
        sqlite
          .prepare(sessionActionSql.insert)
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

interface ConversationMessage {
  readonly sessionId: string
  readonly now: string
  readonly role: "user" | "assistant" | "system"
  readonly messageId: string | undefined
  readonly text: string
  readonly isGenerating: boolean
  readonly attachments: ReadonlyArray<AttachmentRef> | undefined
}

const messageTextLimit = 24_000

const appendConversationMessage = (
  sqlite: ServiceContext["sqlite"],
  message: ConversationMessage
): void => {
  const routeKey = messageRouteKey(message)
  const routed = routedItemId(sqlite, message.sessionId, routeKey)
  const latest = latestChatItemId(sqlite, message.sessionId)
  if (continuesRoutedItem(routed, latest, message)) {
    extendMessageItem(sqlite, routed, message)
  } else {
    createMessageItem(sqlite, message, routeKey)
  }

  touchSession(sqlite, message.sessionId, message.now)
}

const messageRouteKey = (message: ConversationMessage): string | undefined =>
  message.messageId === undefined ? undefined : `message:${message.role}:${message.messageId}`

const routedItemId = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  routeKey: string | undefined
): string | undefined => {
  if (routeKey === undefined) return undefined
  return chatRoute(sqlite, sessionId, routeKey)
}

const continuesRoutedItem = (
  routed: string | undefined,
  latest: string | undefined,
  message: ConversationMessage
): routed is string => routed !== undefined && routed === latest && hasNoAttachments(message)

const hasNoAttachments = (message: ConversationMessage): boolean =>
  message.attachments === undefined || message.attachments.length === 0

const messageStatus = (message: ConversationMessage): "streaming" | "complete" =>
  message.isGenerating ? "streaming" : "complete"

const extendMessageItem = (
  sqlite: ServiceContext["sqlite"],
  itemId: string,
  message: ConversationMessage
): void => {
  const key = `message::${message.messageId}`
  appendTranscriptText(sqlite, itemId, key, message.text)
  sqlite
    .prepare(chatPartSql.replaceText)
    .run(readTranscriptText(sqlite, itemId, key, messageTextLimit), itemId)
  sqlite.prepare(chatItemSql.setStatus).run(messageStatus(message), message.now, itemId)
}

const createMessageItem = (
  sqlite: ServiceContext["sqlite"],
  message: ConversationMessage,
  routeKey: string | undefined
): void => {
  const { sessionId, messageId, attachments } = message
  const itemId = createChatItem(sqlite, sessionId, message.role, message.now, {
    text: message.text,
    ...(messageId === undefined ? {} : { messageId }),
    status: messageStatus(message),
    ...(attachments === undefined ? {} : { attachments })
  })
  if (routeKey !== undefined && hasNoAttachments(message)) {
    setChatRoute(sqlite, sessionId, routeKey, itemId)
  }
}

const latestChatItemId = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string
): string | undefined => idRows.maybe(sqlite.prepare(chatItemSql.latest).get(sessionId))?.id

const touchSession = (sqlite: ServiceContext["sqlite"], sessionId: string, now: string): void => {
  sqlite.prepare(touchSessionSql).run(now, sessionId)
}

const hasMessage = (
  sqlite: ServiceContext["sqlite"],
  rawSessionId: string,
  messageId: string
): boolean =>
  Boolean(sqlite.prepare(chatItemSql.hasMessage).get(canonicalUuid(rawSessionId), messageId))

const hasAnswerAfterMessage = (
  sqlite: ServiceContext["sqlite"],
  rawSessionId: string,
  messageId: string
): boolean =>
  Boolean(
    sqlite.prepare(chatItemSql.answerAfterMessage).get(canonicalUuid(rawSessionId), messageId)
  )

const quietStreamingSessionIds = (
  sqlite: ServiceContext["sqlite"],
  quietSinceIso: string
): ReadonlyArray<string> =>
  sessionIdRows
    .all(sqlite.prepare(chatItemSql.quietStreamingSessions).all(quietSinceIso))
    .map((row) => row.session_id)

const staleStreamingAssistantIds = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  excludeItemId: string | undefined
): ReadonlyArray<string> =>
  idRows
    .all(sqlite.prepare(chatItemSql.staleStreaming).all(sessionId, excludeItemId ?? ""))
    .map((row) => row.id)

const clearCurrentItemAmong = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  itemIds: ReadonlyArray<string>
): void => {
  sqlite.prepare(clearCurrentItemAmongSql(itemIds)).run(sessionId, ...itemIds)
}

const savedActionResponse = (
  sqlite: ServiceContext["sqlite"],
  rawSessionId: string,
  clientActionId: string
): string | undefined =>
  sessionActionRows.maybe(
    sqlite.prepare(sessionActionSql.byId).get(canonicalUuid(rawSessionId), clientActionId)
  )?.response

const sessionIdRows = rowReader({ session_id: textColumn })

const chatItemSql = {
  latest: "select id from chat_items where session_id = ? order by position desc limit 1",
  setStatus:
    "update chat_items set status = ?, updated_at = ?, revision = revision + 1 where id = ?",
  hasMessage: "select 1 from chat_items where session_id = ? and message_id = ? limit 1",
  answerAfterMessage: `select 1
               from chat_items as input
               join chat_items as answer
                 on answer.session_id = input.session_id
                and answer.position > input.position
                and answer.role = 'assistant'
                and answer.status != 'streaming'
               where input.session_id = ? and input.message_id = ?
               limit 1`,
  quietStreamingSessions: `select distinct item.session_id from chat_items as item join sessions on sessions.id = item.session_id
               where item.role = 'assistant' and item.status = 'streaming'
                 and coalesce(sessions.last_event_at, sessions.created_at) <= ?`,
  staleStreaming: `select id from chat_items
               where session_id = ? and role = 'assistant' and status = 'streaming' and id != ?
               order by position asc`
}

const chatPartSql = {
  replaceText:
    "update chat_parts set text = ?, revision = revision + 1 where item_id = ? and kind = 'text'"
}

const touchSessionSql = "update sessions set updated_at = ? where id = ?"

const clearCurrentItemAmongSql = (itemIds: ReadonlyArray<string>): string =>
  `update session_chat_state set current_item_id = null
                 where session_id = ? and current_item_id in (${itemIds.map(() => "?").join(", ")})`

const sessionActionSql = {
  byId: "select * from session_actions where session_id = ? and client_action_id = ?",
  insert: `insert into session_actions (
              session_id, client_action_id, action_kind, response, created_at
            ) values (?, ?, ?, ?, ?)
            on conflict(session_id, client_action_id) do nothing`
}
