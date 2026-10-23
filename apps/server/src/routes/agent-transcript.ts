import type {
  AgentItemKind,
  TranscriptBodyPage,
  TranscriptBodyResource,
  TranscriptItem,
  TranscriptItemDetails,
  TranscriptPage
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { run } from "../server-context.js"
import { asRecord } from "../unknown-values.js"

export interface TranscriptRecord {
  readonly itemId: string
  readonly kind: AgentItemKind
  readonly at: string
  readonly searchText: string
  readonly tool?: string
  readonly payload: Readonly<Record<string, unknown>>
}

export const transcriptPageSize = 16

export const readTranscriptPage = (
  db: CodevisorDatabaseService,
  agentId: string,
  before: number | undefined
): Promise<TranscriptPage> => run(db.getTranscriptPage(agentId, before, transcriptPageSize))

export const olderPagePosition = (page: TranscriptPage): number | undefined => {
  if (!page.hasMore || page.nextBefore === undefined) return undefined
  return Number(page.nextBefore)
}

export const pageRecordsNewestFirst = async (
  db: CodevisorDatabaseService,
  agentId: string,
  page: TranscriptPage
): Promise<ReadonlyArray<TranscriptRecord>> => {
  const newestFirst = page.items.toReversed()
  const perItem = await Promise.all(newestFirst.map((item) => itemRecords(db, agentId, item)))
  return perItem.flatMap((records) => records.toReversed())
}

const itemEntries = async (
  db: CodevisorDatabaseService,
  agentId: string,
  itemId: string
): Promise<ReadonlyArray<TranscriptItemDetails["entries"][number]>> => {
  const entries = new Map<string, TranscriptItemDetails["entries"][number]>()
  let after: string | undefined
  do {
    const page = await run(db.getTranscriptItemDetails(agentId, itemId, after))
    /* v8 ignore next */
    if (page === undefined) break
    for (const entry of page.entries) entries.set(entry.key, entry)
    after = page.nextAfter
  } while (after !== undefined)
  return [...entries.values()].toSorted((left, right) => left.position - right.position)
}

const fullBodyFields = async (
  db: CodevisorDatabaseService,
  agentId: string,
  resource: TranscriptBodyResource
): Promise<Record<string, unknown>> => {
  const fields: Record<string, unknown> = {}
  for (const field of resource.fields) {
    const body = await fullBody(db, agentId, resource, field.name)
    fields[field.name] = field.encoding === "json" ? parsedJson(body) : body
  }
  return fields
}

export const withFullBodies = async (
  db: CodevisorDatabaseService,
  agentId: string,
  record: TranscriptRecord
): Promise<TranscriptRecord> => {
  const payload = await expandedPayload(db, agentId, record.payload)
  if (payload === record.payload) return record
  const searchText = record.kind === "tool" ? toolSearchText(payload) : stringOf(payload.text)
  return { ...record, payload, searchText }
}

const expandedPayload = async (
  db: CodevisorDatabaseService,
  agentId: string,
  payload: Readonly<Record<string, unknown>>
): Promise<Readonly<Record<string, unknown>>> => {
  const resource = payload.detailResource
  if (!isBodyResource(resource)) return payload
  return { ...payload, ...(await fullBodyFields(db, agentId, resource)) }
}

const entryItemId = (itemId: string, entryKey: string): string => `${itemId}:${entryKey}`

const toolPayloadKind = (payload: Readonly<Record<string, unknown>>): AgentItemKind | undefined => {
  if (payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update") {
    return "tool"
  }
  if (payload.sessionUpdate === "agent_message_patch") return "assistant"
  return undefined
}

const itemRecords = async (
  db: CodevisorDatabaseService,
  agentId: string,
  item: TranscriptItem
): Promise<ReadonlyArray<TranscriptRecord>> => {
  if (item.role === "user" || !item.hasDetails) return [messageRecord(item)]
  const entries = await itemEntries(db, agentId, item.id)
  return entries.flatMap((entry) => entryRecords(item, entry))
}

const messageRecord = (item: TranscriptItem): TranscriptRecord => ({
  itemId: item.id,
  kind: messageKind(item),
  at: item.createdAt,
  searchText: item.text,
  payload: { text: item.text, detailResource: item.textResource }
})

const messageKind = (item: TranscriptItem): AgentItemKind => {
  if (item.origin === "event") return "event"
  return item.role
}

const entryRecords = (
  item: TranscriptItem,
  entry: TranscriptItemDetails["entries"][number]
): ReadonlyArray<TranscriptRecord> => {
  const payload = asRecord(entry.payload)
  const kind = toolPayloadKind(payload)
  if (kind === undefined) return []
  const base = { itemId: entryItemId(item.id, entry.key), kind, at: item.createdAt, payload }
  if (kind === "assistant") return [{ ...base, searchText: stringOf(payload.text) }]
  return [{ ...base, tool: stringOf(payload.title), searchText: toolSearchText(payload) }]
}

const toolSearchText = (payload: Readonly<Record<string, unknown>>): string =>
  [payload.title, payload.kind, payload.rawInput, payload.rawOutput].map(stringOf).join("\n")

const fullBody = async (
  db: CodevisorDatabaseService,
  agentId: string,
  resource: TranscriptBodyResource,
  field: string
): Promise<string> => {
  let text = ""
  let position: number | undefined = 0
  while (position !== undefined) {
    const page: TranscriptBodyPage | undefined = await run(
      db.getTranscriptBodyPage(agentId, resource.itemId, resource.entryKey, field, position)
    )
    /* v8 ignore next */
    if (page === undefined) return text
    text += page.text
    position = page.nextPosition
  }
  return text
}

const isBodyResource = (value: unknown): value is TranscriptBodyResource =>
  typeof asRecord(value).entryKey === "string" && Array.isArray(asRecord(value).fields)

const parsedJson = (text: string): unknown => JSON.parse(text) as unknown

export const stringOf = (value: unknown): string => {
  if (value === undefined || value === null) return ""
  if (typeof value === "string") return value
  return JSON.stringify(value)
}
