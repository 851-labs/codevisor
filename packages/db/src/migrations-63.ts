import type { Migration } from "./migration-types.js"

export const migrations63: ReadonlyArray<Migration> = [
  {
    id: 63,
    name: "chat item file changes",
    sql: `
      create table chat_item_file_changes (
        item_id text not null references chat_items(id) on delete cascade,
        tool_call_id text not null,
        path text not null,
        added integer not null,
        removed integer not null,
        status text not null,
        updated_at text not null,
        primary key (item_id, tool_call_id, path)
      );
      insert or ignore into chat_item_file_changes (
        item_id, tool_call_id, path, added, removed, status, updated_at
      )
      select entry.item_id,
        json_extract(entry.payload, '$.toolCallId'),
        json_extract(stat.value, '$.path'),
        coalesce(json_extract(stat.value, '$.added'), 0),
        coalesce(json_extract(stat.value, '$.removed'), 0),
        coalesce(json_extract(entry.payload, '$.status'), 'pending'),
        item.updated_at
      from transcript_entries entry
      join chat_items item on item.id = entry.item_id
      join json_each(
        case when json_valid(entry.payload) then entry.payload else '{}' end,
        '$.diffStats'
      ) stat
      where entry.category = 'tool'
        and json_type(entry.payload, '$.diffStats') = 'array'
        and json_type(entry.payload, '$.toolCallId') = 'text'
        and json_type(stat.value, '$.path') = 'text';
    `
  }
]
