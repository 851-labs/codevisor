import type { Migration } from "./migration-types.js"

export const migrations52: ReadonlyArray<Migration> = [
  {
    id: 52,
    name: "index the retired session event journal's chat item reference",
    // The transcript upgrade keeps the old session event journal as a backup
    // (`legacy_session_events`), and it still declares `chat_item_id
    // references chat_items(id) on delete set null`. Without an index leading
    // on chat_item_id, every deleted chat item scans that whole table -- and
    // chat_item_id sits after the large payload column, so each row read walks
    // its overflow pages. Deleting a chat of a few hundred items against a
    // 1.4 GB backup pinned the server's event loop for minutes.
    //
    // Databases not yet cut over still hold the reference on `session_events`;
    // the index follows that table when the cutover renames it.
    sql: "",
    run: (sqlite) => {
      for (const table of ["legacy_session_events", "session_events"]) {
        const references = sqlite
          .prepare(
            "select 1 from pragma_foreign_key_list(?) where \"table\" = 'chat_items' and \"from\" = 'chat_item_id'"
          )
          .get(table)
        if (references === undefined) continue
        sqlite.exec(
          `create index if not exists session_events_chat_item_fk_idx on "${table}"(chat_item_id)`
        )
        return
      }
    }
  }
]
