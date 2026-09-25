import type { Migration } from "./migration-types.js"

export const migrations53: ReadonlyArray<Migration> = [
  {
    id: 53,
    name: "drop the retired event journals and index chat item routes by item",
    // The transcript upgrade used to keep the pre-cutover journals as
    // `legacy_events` and `legacy_session_events`. Nothing reads them, and the
    // renamed tables kept their foreign keys: every deleted chat item scanned
    // the whole multi-GB backup to null its `chat_item_id`, pinning the
    // server's event loop for the length of a chat delete. The cutover now
    // drops the old journals itself; this clears databases already cut over.
    //
    // chat_item_routes cascades from chat_items but is keyed by session, so
    // each deleted item also scanned every route: a 10,000-item chat took 18 s.
    sql: `
      drop table if exists legacy_session_events;
      drop table if exists legacy_events;
      create index if not exists chat_item_routes_item_idx on chat_item_routes(item_id);
    `
  }
]
