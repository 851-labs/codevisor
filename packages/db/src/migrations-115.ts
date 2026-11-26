import type Database from "better-sqlite3"

import type { Migration } from "./migration-types.js"
import { rowReader, text } from "./row-reader.js"

const harnesslessChats = `
  select id from sessions
  where harness_id = ''
    and not exists (select 1 from chat_items where chat_items.session_id = sessions.id)
    and not exists (select 1 from conversation_items where conversation_items.session_id = sessions.id)
    and not exists (select 1 from transcript_items where transcript_items.session_id = sessions.id)
    and not exists (select 1 from bots where bots.session_id = sessions.id)
`

const sessionReferenceRows = rowReader({ name: text, column: text })

const deleteHarnesslessChatsWithEveryRowReferencingThem = (sqlite: Database.Database): void => {
  sqlite.exec(`create temp table dropped_chats as ${harnesslessChats}`)
  sqlite.exec(`
    delete from plugin_event_deliveries where subscription_id in (
      select id from plugin_event_subscriptions where session_id in (select id from dropped_chats)
    );
    delete from workspace_panes
      where resource_kind = 'session' and resource_id in (select id from dropped_chats);
  `)
  const references = sqlite
    .prepare(
      `select m.name as name, f."from" as column
         from sqlite_master m, pragma_foreign_key_list(m.name) f
        where m.type = 'table' and f."table" = 'sessions'`
    )
    .all()
    .map((row) => sessionReferenceRows.one(row))
  for (const reference of references) {
    sqlite.exec(
      `delete from ${reference.name} where ${reference.column} in (select id from dropped_chats)`
    )
  }
  sqlite.exec(`
    delete from sessions where id in (select id from dropped_chats);
    drop table dropped_chats;
  `)
}

export const migrations115: ReadonlyArray<Migration> = [
  {
    id: 115,
    name: "every chat has a harness: drop empty chats without one, and give the rest Claude Code",
    sql: "",
    run: (sqlite) => {
      deleteHarnesslessChatsWithEveryRowReferencingThem(sqlite)
      sqlite.exec("update sessions set harness_id = 'claude-code' where harness_id = ''")
    }
  }
]
