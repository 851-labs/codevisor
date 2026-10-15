import type { Migration } from "./migration-types.js"

export const migrations62: ReadonlyArray<Migration> = [
  {
    id: 62,
    name: "chat item tool media",
    sql: `
      create table chat_item_media (
        item_id text not null references chat_items(id) on delete cascade,
        file_id text not null,
        created_at text not null,
        primary key (item_id, file_id)
      );
      create index chat_item_media_file on chat_item_media(file_id);
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
          where files.id = json_extract(file.value, '$.fileId') and files.mime_type like 'image/%'
        );
    `
  }
]
