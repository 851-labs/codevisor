import type { Migration } from "./migration-types.js"

export const migrations71: ReadonlyArray<Migration> = [
  {
    id: 71,
    name: "workspace video media",
    sql: `
      create table media_durations (
        sha256 text primary key,
        duration_ms integer
      );
      insert or ignore into chat_item_media (item_id, file_id, created_at)
      select entry.item_id, json_extract(file.value, '$.fileId'), item.created_at
      from transcript_entries entry
      join chat_items item on item.id = entry.item_id
      join json_each(
        case when json_valid(entry.payload) then entry.payload else '{}' end,
        '$._meta.codevisorExecution.calls'
      ) call
      join json_each(call.value, '$.files') file
      where entry.category = 'tool'
        and exists (
          select 1 from files
          where files.id = json_extract(file.value, '$.fileId') and files.mime_type like 'video/%'
        );
    `
  }
]
