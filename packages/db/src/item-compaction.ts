import type { ContextCompactionStatus } from "@codevisor/api"

import { integer, literal, nullable, rowReader } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export const itemCompaction = (
  sqlite: ServiceContext["sqlite"],
  itemId: string
): ContextCompactionStatus | undefined => {
  const row = compactionRows.one(sqlite.prepare(compactionSummarySql).get(itemId, itemId))
  if (!onlyCompacted(row) || row.status === null) return undefined
  return row.status
}

interface CompactionSummary {
  readonly entries: number
  readonly compactions: number
}

const onlyCompacted = (row: CompactionSummary): boolean =>
  row.entries > 0 && row.entries === row.compactions

const compactionRows = rowReader({
  entries: integer,
  compactions: integer,
  status: nullable(literal("started", "completed", "failed"))
})

const compactionSummarySql = `select count(*) as entries,
    count(*) filter (where category = 'compaction') as compactions,
    (select json_extract(payload, '$.status') from transcript_entries
      where item_id = ? and category = 'compaction' order by position desc limit 1) as status
  from transcript_entries where item_id = ?`
