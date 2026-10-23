import type { AgentItem, AgentItemKind, AgentSearchHit, AgentSearchResult } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Schema } from "effect"

import { HttpFailure } from "../server-context.js"
import { stringField } from "../unknown-values.js"
import {
  olderPagePosition,
  pageRecordsNewestFirst,
  readTranscriptPage,
  stringOf,
  withFullBodies,
  type TranscriptRecord
} from "./agent-transcript.js"

export interface AgentSearchFilters {
  readonly query: string | undefined
  readonly kinds: ReadonlySet<AgentItemKind> | undefined
  readonly tool: string | undefined
  readonly last: number
  readonly next: string | undefined
}

export const defaultSearchLast = 20
export const maxSearchLast = 200
const snippetRadius = 80

export const searchAgentTranscript = async (
  db: CodevisorDatabaseService,
  agentId: string,
  filters: AgentSearchFilters
): Promise<AgentSearchResult> => {
  const hits: Array<AgentSearchHit> = []
  let cursor = decodeSearchCursor(filters.next)
  for (;;) {
    const page = await readTranscriptPage(db, agentId, cursor.before)
    const matches = await matchingRecords(
      db,
      agentId,
      await pageRecordsNewestFirst(db, agentId, page),
      filters
    )
    const remaining = filters.last - hits.length
    const taken = matches.slice(cursor.skip, cursor.skip + remaining)
    hits.push(...taken.map((record) => searchHit(record, filters.query)))
    if (cursor.skip + taken.length < matches.length) {
      return { items: hits, next: encodeSearchCursor(cursor.before, cursor.skip + taken.length) }
    }
    const older = olderPagePosition(page)
    if (older === undefined) return { items: hits }
    if (hits.length >= filters.last) return { items: hits, next: encodeSearchCursor(older, 0) }
    cursor = { before: older, skip: 0 }
  }
}

export const readAgentItem = async (
  db: CodevisorDatabaseService,
  agentId: string,
  itemId: string
): Promise<AgentItem> =>
  agentItem(await withFullBodies(db, agentId, await findRecord(db, agentId, itemId)))

const matchingRecords = async (
  db: CodevisorDatabaseService,
  agentId: string,
  records: ReadonlyArray<TranscriptRecord>,
  filters: AgentSearchFilters
): Promise<ReadonlyArray<TranscriptRecord>> => {
  const candidates = records.filter(
    (record) => matchesKind(record, filters.kinds) && matchesTool(record, filters.tool)
  )
  const searched = await Promise.all(
    candidates.map((record) => searchableRecord(db, agentId, record, filters.query))
  )
  return searched.filter((record) => contains(record.searchText, filters.query))
}

const searchableRecord = async (
  db: CodevisorDatabaseService,
  agentId: string,
  record: TranscriptRecord,
  query: string | undefined
): Promise<TranscriptRecord> => {
  if (contains(record.searchText, query)) return record
  return withFullBodies(db, agentId, record)
}

const matchesKind = (record: TranscriptRecord, kinds: AgentSearchFilters["kinds"]): boolean =>
  kinds === undefined || kinds.has(record.kind)

const matchesTool = (record: TranscriptRecord, tool: string | undefined): boolean => {
  if (tool === undefined) return true
  if (record.kind !== "tool") return false
  return contains([record.tool, stringField(record.payload, "kind")].join(" "), tool)
}

const contains = (text: string, query: string | undefined): boolean =>
  query === undefined || text.toLowerCase().includes(query.toLowerCase())

const searchHit = (record: TranscriptRecord, query: string | undefined): AgentSearchHit => ({
  itemId: record.itemId,
  kind: record.kind,
  ...(record.tool === undefined ? {} : { tool: record.tool }),
  at: record.at,
  snippet: snippet(record.searchText, query)
})

const snippet = (text: string, query: string | undefined): string => {
  const flat = text.replaceAll(/\s+/g, " ").trim()
  const index = query === undefined ? 0 : flat.toLowerCase().indexOf(query.toLowerCase())
  const start = Math.max(0, index - snippetRadius)
  const end = Math.min(flat.length, Math.max(index, 0) + (query?.length ?? 0) + snippetRadius)
  return `${start > 0 ? "…" : ""}${flat.slice(start, end)}${end < flat.length ? "…" : ""}`
}

interface SearchCursor {
  readonly before: number | undefined
  readonly skip: number
}

const encodeSearchCursor = (before: number | undefined, skip: number): string =>
  Buffer.from(JSON.stringify({ before, skip })).toString("base64url")

const SearchCursorSchema = Schema.Struct({
  before: Schema.optional(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))),
  skip: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))
})

const decodeSearchCursor = (next: string | undefined): SearchCursor => {
  if (next === undefined) return { before: undefined, skip: 0 }
  try {
    const cursor = Schema.decodeUnknownSync(SearchCursorSchema)(
      JSON.parse(Buffer.from(next, "base64url").toString())
    )
    return { before: cursor.before, skip: cursor.skip }
  } catch {
    throw new HttpFailure(400, "next must be a cursor returned by an earlier search")
  }
}

const findRecord = async (
  db: CodevisorDatabaseService,
  agentId: string,
  itemId: string
): Promise<TranscriptRecord> => {
  let before: number | undefined
  do {
    const page = await readTranscriptPage(db, agentId, before)
    const records = await pageRecordsNewestFirst(db, agentId, page)
    const found = records.find((record) => record.itemId === itemId)
    if (found !== undefined) return found
    before = olderPagePosition(page)
  } while (before !== undefined)
  throw new HttpFailure(404, `Item not found: ${itemId}`)
}

const agentItem = (record: TranscriptRecord): AgentItem => {
  const base = { itemId: record.itemId, kind: record.kind, at: record.at }
  if (record.kind !== "tool") return { ...base, text: stringOf(record.payload.text) }
  return {
    ...base,
    ...optionalString("tool", stringField(record.payload, "title")),
    ...optionalString("status", stringField(record.payload, "status")),
    input: record.payload.rawInput,
    output: record.payload.rawOutput
  }
}

const optionalString = (name: string, value: string | undefined): Record<string, string> =>
  value === undefined ? {} : { [name]: value }
