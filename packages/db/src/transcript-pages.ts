import type { TranscriptPage } from "@codevisor/api"

import { chatAssistantSummary, sessionGoalSnapshot } from "./chat-items.js"
import {
  backgroundTasksFromRaw,
  pendingQuestionFromRaw,
  sessionPlanFromRaw
} from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import { transcriptFromChatRow } from "./row-mappers.js"
import type { ChatItemRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import { sessionSetupState } from "./setup-state.js"
import { transcriptTextResource } from "./transcript-bodies.js"

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

const resolveTranscriptPosition = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  rawBefore: number | string | undefined
) => {
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
  return before
}

const transcriptRowsWithinBudget = (
  candidates: ReadonlyArray<ChatItemRow>,
  bounded: number
): ChatItemRow[] => {
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
  return pageRows
}

const transcriptPageItem = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  row: ChatItemRow
) => {
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
}

const readTranscriptPageRows = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  before: number | undefined,
  bounded: number,
  forward: boolean
) => {
  return sqlite
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
    .all(sessionId, before ?? null, before ?? null, bounded + 1) as ReadonlyArray<ChatItemRow>
}

const hasOlderRenderableTranscriptItem = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  first: number | undefined
) => {
  return (
    first !== undefined &&
    sqlite
      .prepare(
        `select 1 from chat_items where session_id = ?
          and ${renderableChatItemPredicate} and position < ? limit 1`
      )
      .get(sessionId, first) !== undefined
  )
}

const hasNewerRenderableTranscriptItem = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  last: number | undefined
) => {
  return (
    last !== undefined &&
    sqlite
      .prepare(
        `select 1 from chat_items where session_id = ?
          and ${renderableChatItemPredicate} and position > ? limit 1`
      )
      .get(sessionId, last) !== undefined
  )
}

const readTranscriptPageState = (sqlite: ServiceContext["sqlite"], sessionId: string) => {
  return sqlite
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
}

const readTranscriptStateUpdates = (sqlite: ServiceContext["sqlite"], sessionId: string) => {
  return (
    sqlite
      .prepare(
        `select payload from session_state where session_id = ?
            and state_key in ('available_commands_update', 'config_option_update', 'current_mode_update')`
      )
      .all(sessionId) as Array<{ payload: string }>
  ).map((row) => JSON.parse(row.payload) as unknown)
}

const makeTranscriptPage = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  session: ReturnType<ServiceContext["getSession"]>,
  ordered: ReadonlyArray<ChatItemRow>
) => {
  const items = ordered.map((row) => transcriptPageItem(sqlite, sessionId, row))
  const first = ordered[0]?.position
  const last = ordered.at(-1)?.position
  const hasMore = hasOlderRenderableTranscriptItem(sqlite, sessionId, first)
  const hasNewer = hasNewerRenderableTranscriptItem(sqlite, sessionId, last)
  const state = readTranscriptPageState(sqlite, sessionId)
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
    stateUpdates: readTranscriptStateUpdates(sqlite, sessionId),
    ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
    pendingPlanApproval: session.pendingPlanApproval === true,
    backgroundTasks,
    ...(goal === undefined ? {} : { goal }),
    ...(sessionPlan === undefined ? {} : { sessionPlan }),
    usage: session.usage
  }
}

export const readTranscriptPage = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  session: ReturnType<ServiceContext["getSession"]>,
  rawBefore: number | string | undefined,
  limit: number,
  forward: boolean
): TranscriptPage => {
  const before = resolveTranscriptPosition(sqlite, sessionId, rawBefore)
  const bounded = Math.max(1, Math.min(64, Math.trunc(limit)))
  const rows = readTranscriptPageRows(sqlite, sessionId, before, bounded, forward)
  const candidates = rows.slice(0, bounded)
  const pageRows = transcriptRowsWithinBudget(candidates, bounded)
  const ordered = forward ? pageRows : pageRows.toReversed()
  return makeTranscriptPage(sqlite, sessionId, session, ordered)
}
