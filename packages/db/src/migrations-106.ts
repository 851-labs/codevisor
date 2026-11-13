import type { Migration } from "./migration-types.js"

export const migrations106: ReadonlyArray<Migration> = [
  {
    id: 106,
    name: "a conversation can include a bot or an agent that lives on another machine",
    sql: `
      alter table conversation_participants add column remote_bot_id text;
      alter table conversation_participants add column name text;
    `
  }
]
