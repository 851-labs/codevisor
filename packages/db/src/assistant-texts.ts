import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { readTranscriptText } from "./transcript-state.js"

export interface OpenAssistantText {
  readonly itemId: string
  readonly entryKey: string
  readonly parentToolCallId: string
}

export const makeAssistantTextsService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "listOpenAssistantTexts" | "readAssistantText"> => {
  const { sqlite } = context

  return {
    listOpenAssistantTexts: (sessionId) =>
      attempt("listOpenAssistantTexts", () =>
        openTextRows
          .all(sqlite.prepare(openTextsSql).all(canonicalUuid(sessionId)))
          .map(openAssistantText)
      ),
    readAssistantText: (itemId, entryKey) =>
      attempt("readAssistantText", () => readTranscriptText(sqlite, itemId, entryKey))
  }
}

const openAssistantText = (row: OpenTextRow): OpenAssistantText => ({
  itemId: row.item_id,
  entryKey: row.entry_key,
  parentToolCallId: row.parent_id
})

const openTextRows = rowReader({ item_id: text, entry_key: text, parent_id: text })

type OpenTextRow = ReturnType<typeof openTextRows.one>

const openTextsSql = `select heads.item_id, heads.entry_key, heads.parent_id from transcript_heads heads
    join chat_items items on items.id = heads.item_id
    where items.session_id = ? and items.role = 'assistant' and items.status = 'streaming'
      and heads.category = 'text'
    order by heads.item_id, heads.parent_id`
