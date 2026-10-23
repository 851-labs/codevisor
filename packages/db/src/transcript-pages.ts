import type { QuestionOutcome, QuestionPresentation, TranscriptPage } from "@codevisor/api"

import { chatAssistantSummary, sessionGoalSnapshot } from "./chat-items.js"
import { entryKeyRows, payloadRows } from "./common-rows.js"
import { parseJsonRecord, type JsonRecord } from "./event-payloads.js"
import {
  backgroundTasksFromRaw,
  pendingQuestionFromRaw,
  sessionPlanFromRaw
} from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import { transcriptFromChatRow } from "./row-mappers.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"
import { chatItemRows, type ChatItemRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import { readSessionSkills } from "./session-skills.js"
import { setupQuestionPresentation } from "./setup-questions.js"
import { sessionSetupState } from "./setup-state.js"
import { transcriptTextResource } from "./transcript-bodies.js"

export const renderableChatItemPredicate = `(
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

const positionRows = rowReader({ position: integer })

const pageStateRows = rowReader({
  cursor: integer,
  pending_question: nullable(text),
  background_tasks: text,
  session_plan: nullable(text)
})

const maxInitialTranscriptPageCharacters = 24_000
const maxOlderTranscriptPageCharacters = 64_000

const resolveTranscriptPosition = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  rawBefore: number | string | undefined
) => {
  if (typeof rawBefore !== "string") return rawBefore

  const before = cursorItemPosition(sqlite, sessionId, rawBefore)
  if (before === undefined) throw new Error("Transcript cursor item no longer exists")
  return before
}

const cursorItemPosition = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  rawItemId: string
): number | undefined =>
  positionRows.maybe(
    sqlite
      .prepare(transcriptPageSql.cursorItemPosition)
      .get(sessionId, canonicalUuid(rawItemId), canonicalUuid(rawItemId))
  )?.position

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

const questionOutcomes: ReadonlySet<unknown> = new Set<QuestionOutcome>([
  "answered",
  "cancelled",
  "autoResolved"
])

const isQuestionOutcome = (value: unknown): value is QuestionOutcome => questionOutcomes.has(value)

const questionEntriesSql =
  "select payload from transcript_entries where item_id = ? and category = 'question' order by position"

const questionEntryPayloads = (
  sqlite: ServiceContext["sqlite"],
  itemId: string
): ReadonlyArray<string> =>
  payloadRows.all(sqlite.prepare(questionEntriesSql).all(itemId)).map((row) => row.payload)

interface SetupRequestSummary {
  readonly questionId: string
  readonly presentation: QuestionPresentation
  readonly outcome?: QuestionOutcome
}

const transcriptSetupRequests = (
  sqlite: ServiceContext["sqlite"],
  itemId: string,
  pendingQuestionId: string | undefined
): ReadonlyArray<SetupRequestSummary> =>
  latestSetupRequests(questionEntryPayloads(sqlite, itemId)).map((request) =>
    withAbandonedOutcome(request, pendingQuestionId)
  )

const latestSetupRequests = (
  payloads: ReadonlyArray<string>
): ReadonlyArray<SetupRequestSummary> => {
  const byQuestion = new Map<string, SetupRequestSummary>()
  for (const raw of payloads) {
    const request = setupRequestSummary(parseJsonRecord(raw))
    if (request !== undefined) byQuestion.set(request.questionId, request)
  }
  return [...byQuestion.values()]
}

const setupRequestSummary = (payload: JsonRecord | undefined): SetupRequestSummary | undefined => {
  const questionId = payload?.questionId
  const presentation = setupQuestionPresentation(payload)
  if (typeof questionId !== "string" || presentation === undefined) return undefined

  if (!isQuestionOutcome(payload?.outcome)) return { questionId, presentation }
  return { questionId, presentation, outcome: payload.outcome }
}

const withAbandonedOutcome = (
  request: SetupRequestSummary,
  pendingQuestionId: string | undefined
): SetupRequestSummary => {
  if (request.outcome !== undefined || request.questionId === pendingQuestionId) return request
  return { ...request, outcome: "cancelled" }
}

const transcriptPageItem = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  row: ChatItemRow,
  pendingQuestionId: string | undefined
) => {
  const item = transcriptFromChatRow(row)
  if (row.role !== "assistant") {
    const entryKey = firstTextEntryKey(sqlite, row.id)
    return { ...item, ...textResourceIfPresent(sqlite, row, entryKey) }
  }
  const summary = chatAssistantSummary(sqlite, sessionId, row.id)
  const setupRequests = transcriptSetupRequests(sqlite, row.id, pendingQuestionId)
  return {
    ...(setupRequests.length === 0 ? {} : { setupRequests }),
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

const textResourceIfPresent = (
  sqlite: ServiceContext["sqlite"],
  row: ChatItemRow,
  entryKey: string | undefined
) => {
  if (entryKey === undefined) return {}
  return { textResource: transcriptTextResource(sqlite, row.id, entryKey) }
}

const firstTextEntryKey = (sqlite: ServiceContext["sqlite"], itemId: string): string | undefined =>
  entryKeyRows.maybe(sqlite.prepare(transcriptPageSql.firstTextEntry).get(itemId))?.entry_key

const readTranscriptPageRows = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  before: number | undefined,
  bounded: number,
  forward: boolean
) => {
  return chatItemRows.all(
    sqlite.prepare(pageRowsSql(forward)).all(sessionId, before ?? null, before ?? null, bounded + 1)
  )
}

const hasOlderRenderableTranscriptItem = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  first: number | undefined
) => {
  return (
    first !== undefined &&
    sqlite.prepare(transcriptPageSql.olderRenderableItem).get(sessionId, first) !== undefined
  )
}

const hasNewerRenderableTranscriptItem = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  last: number | undefined
) => {
  return (
    last !== undefined &&
    sqlite.prepare(transcriptPageSql.newerRenderableItem).get(sessionId, last) !== undefined
  )
}

const readTranscriptPageState = (sqlite: ServiceContext["sqlite"], sessionId: string) => {
  return pageStateRows.one(sqlite.prepare(transcriptPageSql.pageState).get(sessionId))
}

const readTranscriptStateUpdates = (sqlite: ServiceContext["sqlite"], sessionId: string) => {
  return payloadRows
    .all(sqlite.prepare(transcriptPageSql.stateUpdates).all(sessionId))
    .map((row) => JSON.parse(row.payload) as unknown)
}

const makeTranscriptPage = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  session: ReturnType<ServiceContext["getSession"]>,
  ordered: ReadonlyArray<ChatItemRow>
) => {
  const state = readTranscriptPageState(sqlite, sessionId)
  const pendingQuestion = pendingQuestionFromRaw(state.pending_question)
  const items = ordered.map((row) =>
    transcriptPageItem(sqlite, sessionId, row, pendingQuestion?.questionId)
  )
  const first = ordered[0]?.position
  const last = ordered.at(-1)?.position
  const hasMore = hasOlderRenderableTranscriptItem(sqlite, sessionId, first)
  const hasNewer = hasNewerRenderableTranscriptItem(sqlite, sessionId, last)
  const backgroundTasks = backgroundTasksFromRaw(state.background_tasks)
  const sessionPlan = sessionPlanFromRaw(state.session_plan)
  const goal = sessionGoalSnapshot(sqlite, sessionId)
  const skills = readSessionSkills(sqlite, sessionId)
  return {
    items,
    setupActivities: sessionSetupState(sqlite, sessionId),
    ...(hasMore ? { nextBefore: String(first!) } : {}),
    ...(last === undefined ? {} : { nextAfter: `after:${last}` }),
    hasNewer,
    hasMore,
    eventCursor: state.cursor,
    stateUpdates: readTranscriptStateUpdates(sqlite, sessionId),
    ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
    pendingPlanApproval: session.pendingPlanApproval === true,
    backgroundTasks,
    ...(goal === undefined ? {} : { goal }),
    ...(skills === undefined ? {} : { skills }),
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

const pageRowsSql = (forward: boolean): string =>
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

const transcriptPageSql = {
  cursorItemPosition:
    "select position from chat_items where session_id = ? and (id = ? or lower(message_id) = ?)",
  firstTextEntry:
    "select entry_key from transcript_entries where item_id = ? and category = 'text' order by position limit 1",
  olderRenderableItem: `select 1 from chat_items where session_id = ?
          and ${renderableChatItemPredicate} and position < ? limit 1`,
  newerRenderableItem: `select 1 from chat_items where session_id = ?
          and ${renderableChatItemPredicate} and position > ? limit 1`,
  pageState: `select revision as cursor, pending_question, background_tasks, session_plan
             from sessions where id = ?`,
  stateUpdates: `select payload from session_state where session_id = ?
            and state_key in ('available_commands_update', 'config_option_update', 'current_mode_update')`
}
