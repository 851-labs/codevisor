import type { Migration } from "./migration-types.js"

export const migrations53: ReadonlyArray<Migration> = [
  {
    id: 53,
    name: "drop the retired event journals and index chat item routes by item",
    sql: `
      drop table if exists legacy_session_events;
      drop table if exists legacy_events;
      create index if not exists chat_item_routes_item_idx on chat_item_routes(item_id);
    `
  }
]
