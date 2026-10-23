import type { Migration } from "./migration-types.js"

export const migrations74: ReadonlyArray<Migration> = [
  {
    id: 74,
    name: "remote bot workspaces",
    sql: `
      alter table workspaces add column remote_bot_id text;
      alter table workspaces add column remote_bot_machine_id text;
    `
  }
]
