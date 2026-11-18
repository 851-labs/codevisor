import type { Migration } from "./migration-types.js"

export const migrations113: ReadonlyArray<Migration> = [
  {
    id: 113,
    name: "find the plugin setup cards shown in chats",
    sql: `
      create index transcript_entries_plugin_setup on transcript_entries(item_id)
        where category = 'plugin_setup';
    `
  }
]
